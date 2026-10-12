import Foundation

// Breeze ASR 25 dictation: the pause chunker, the prompt, the install check,
// the model picker, and live piece-by-piece transcription with a fake
// transcriber. Synthetic audio only: these never prove a real mic or a real
// whisper.cpp run (that still needs `bash check.sh hardware` and a manual take).

// MARK: - Synthetic takes

private let breezeTestRate = 16_000
private let breezeTestFrame = 320 // 20 ms

private func breezeSamples(_ seconds: Double) -> Int {
    Int((seconds * Double(breezeTestRate)).rounded())
}

/// A take built from speech and silence segments, remembering where speech is.
private struct BreezeTestTake {
    private(set) var samples: [Float] = []
    private(set) var speechRanges: [Range<Int>] = []
    private var noiseState: UInt32 = 0x1234_5678

    /// Speech as words: 0.24 s of a 220 Hz sine (RMS = amplitude / sqrt(2))
    /// with 0.08 s gaps between words, ending on a word. Real speech dips
    /// between syllables like this; the gaps are far shorter than any pause.
    /// `seconds` is rounded to whole words (n words = n * 0.32 - 0.08 s).
    mutating func speech(_ seconds: Double, amplitude: Float = 0.1) {
        let words = max(1, Int(((seconds + 0.08) / 0.32).rounded()))
        let start = samples.count
        for word in 0..<words {
            if word > 0 { silence(0.08) }
            tone(0.24, amplitude: amplitude)
        }
        speechRanges.append(start..<samples.count)
    }

    /// A steady voice with no dips at all.
    mutating func steadySpeech(_ seconds: Double, amplitude: Float = 0.1) {
        let start = samples.count
        tone(seconds, amplitude: amplitude)
        speechRanges.append(start..<samples.count)
    }

    private mutating func tone(_ seconds: Double, amplitude: Float) {
        let start = samples.count
        for index in 0..<breezeSamples(seconds) {
            let phase = 2 * Double.pi * 220 * Double(start + index) / Double(breezeTestRate)
            samples.append(amplitude * Float(sin(phase)))
        }
    }

    /// Faint noise, RMS about 0.0002.
    mutating func silence(_ seconds: Double) {
        for _ in 0..<breezeSamples(seconds) {
            noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
            let unit = Float(noiseState >> 8) / Float(1 << 24) // 0..<1
            samples.append((unit * 2 - 1) * 0.0004)
        }
    }

    var count: Int { samples.count }
}

private func breezeFeed(
    _ samples: [Float],
    blockSize: Int,
    into chunker: inout DictationPauseChunker,
    onEvents: (inout DictationPauseChunker, [DictationPauseChunker.Event]) -> Void = { _, _ in }
) -> [DictationPauseChunker.Event] {
    var events: [DictationPauseChunker.Event] = []
    var offset = 0
    while offset < samples.count {
        let end = min(samples.count, offset + blockSize)
        let produced = chunker.append(Array(samples[offset..<end]))
        onEvents(&chunker, produced)
        events += produced
        offset = end
    }
    return events
}

/// Promise A1: every cut lands in silence, at least the pause after speech.
private func breezeAssertCutsInSilence(
    _ events: [DictationPauseChunker.Event],
    _ take: BreezeTestTake,
    commitPause: Double = 0.5,
    _ label: String
) {
    for event in events {
        assertTrue(event.start >= 0 && event.start < event.end && event.end <= take.count,
                   "\(label): \(event) is a real span of the take")
        let insideSpeech = take.speechRanges.contains { $0.lowerBound < event.end && event.end < $0.upperBound }
        assertFalse(insideSpeech, "\(label): \(event) ends inside speech")
        guard let speechEnd = take.speechRanges.map(\.upperBound).filter({ $0 <= event.end }).max() else {
            recordFailure("\(label): \(event) has no speech before it")
            continue
        }
        let pause = event.kind == .speculate ? 0.3 : commitPause
        assertTrue(event.end - speechEnd >= breezeSamples(pause) - breezeTestFrame,
                   "\(label): \(event) ends \(event.end - speechEnd) samples after speech, needs \(pause) s")
    }
}

// MARK: - Fake transcriber

private struct BreezeTestFailure: Error {}

/// Records every call and returns "piece<n>-amp<peak*100>", so a text names
/// both its call and which speech segment (by loudness) it was cut from.
private final class BreezeTestTranscriber: BreezePieceTranscribing, @unchecked Sendable {
    struct Call {
        let sampleCount: Int
        let amplitudeTag: Int
        let language: String?
        let prompt: String
        let text: String
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private let failsFor: @Sendable (_ amplitudeTag: Int) -> Bool

    init(failsFor: @escaping @Sendable (_ amplitudeTag: Int) -> Bool = { _ in false }) {
        self.failsFor = failsFor
    }

    var calls: [Call] { lock.withLock { recorded } }

    func transcribe(
        _ samples: [Float],
        language: String?,
        prompt: String,
        cancellation: WhisperCppCancellation
    ) async throws -> String {
        let peak = samples.map { abs($0) }.max() ?? 0
        let tag = Int((peak * 100).rounded())
        let call: Call = lock.withLock {
            let call = Call(
                sampleCount: samples.count,
                amplitudeTag: tag,
                language: language,
                prompt: prompt,
                text: "piece\(recorded.count + 1)-amp\(tag)"
            )
            recorded.append(call)
            return call
        }
        if failsFor(tag) { throw BreezeTestFailure() }
        return call.text
    }

    func amplitudeTag(ofText text: String) -> Int? {
        calls.first { $0.text == text }?.amplitudeTag
    }
}

/// Polls up to `polls` x 100 ms; returns whether the condition came true.
private func breezeWait(polls: Int = 150, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<polls {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return condition()
}

/// Waits until the fake has had no new call for half a second (sync only, not asserted).
private func breezeWaitForQuiet(_ fake: BreezeTestTranscriber) async {
    var lastCount = -1
    var quietPolls = 0
    for _ in 0..<100 where quietPolls < 5 {
        let count = fake.calls.count
        quietPolls = count == lastCount ? quietPolls + 1 : 0
        lastCount = count
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}

private func breezeStartLive(
    _ take: BreezeTestTake,
    fake: BreezeTestTranscriber,
    language: String? = "ru",
    until ready: @escaping ([BreezeTestTranscriber.Call]) -> Bool
) async -> BreezeLiveDictation {
    let live = BreezeLiveDictation(transcriber: fake, language: language, prompt: { "PROMPT<\($0)>" })
    live.start()
    var offset = 0
    while offset < take.count {
        let end = min(take.count, offset + 1_600)
        live.sink.append(Array(take.samples[offset..<end]), sampleRate: 16_000)
        offset = end
    }
    let gotThere = await breezeWait { ready(fake.calls) }
    assertTrue(gotThere, "the live dictation transcribed the expected pieces while recording")
    await breezeWaitForQuiet(fake)
    return live
}

// Amplitude tags of the speech segments used in the live takes.
private let breezeTagA = 8   // peak 0.08, RMS ~0.057
private let breezeTagB = 14  // peak 0.14, RMS ~0.099
private let breezeTagC = 11  // peak 0.11, RMS ~0.078

// MARK: - Tests

func testBreezeDictation() async {
    // A. DictationPauseChunker

    runSuite("Pause chunker: after 3 s of speech a 0.5 s pause commits contiguous pieces in order, and pieceStart moves to the cut") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4); take.silence(0.8)
        take.speech(4); take.silence(0.8)
        take.speech(4); take.silence(0.8)
        var chunker = DictationPauseChunker()
        let events = breezeFeed(take.samples, blockSize: 1_600, into: &chunker) { chunker, produced in
            if let lastCommit = produced.last(where: { $0.kind == .commit }) {
                assertEqual(chunker.pieceStart, lastCommit.end, "pieceStart moves to the cut")
            }
        }
        let commits = events.filter { $0.kind == .commit }
        assertEqual(commits.count, 3, "one commit per pause after 4 s of speech")
        assertEqual(commits.first?.start, 0)
        for index in commits.indices.dropFirst() {
            assertEqual(commits[index].start, commits[index - 1].end, "pieces are contiguous")
            assertTrue(commits[index].end > commits[index - 1].end, "pieces are in order")
        }
        for (index, commit) in commits.enumerated() {
            let pauseStart = take.speechRanges[index].upperBound
            let pauseEnd = index + 1 < take.speechRanges.count ? take.speechRanges[index + 1].lowerBound : take.count
            assertTrue(commit.end > pauseStart && commit.end <= pauseEnd, "commit \(index) cuts in its own pause")
        }
        var pieceStart = 0
        for event in events {
            if event.kind == .speculate {
                assertEqual(event.start, pieceStart, "a speculation covers the current piece")
            } else {
                pieceStart = event.end
            }
        }
        assertEqual(chunker.pieceStart, commits.last?.end ?? -1)
        assertNotNil(chunker.lastSpeechEnd)
        assertEqual(chunker.receivedSamples, take.count)
        breezeAssertCutsInSilence(events, take, "three pieces")
    }

    runSuite("Pause chunker: under 3 s of speech a long pause speculates but never commits") {
        var short = BreezeTestTake()
        short.silence(0.5) // the moment before the first word
        short.speech(2); short.silence(2)
        var chunker = DictationPauseChunker()
        let events = breezeFeed(short.samples, blockSize: 1_600, into: &chunker)
        assertTrue(events.contains { $0.kind == .speculate }, "a long pause still speculates")
        assertFalse(events.contains { $0.kind == .commit }, "2 s of speech is too short to commit")
        assertTrue(events.allSatisfy { $0.start == 0 })
        breezeAssertCutsInSilence(events, short, "2 s then a long pause")

        // 2.5 s of speech spread over a longer piece still counts as under 3 s of speech.
        var spread = BreezeTestTake()
        spread.silence(0.5) // the moment before the first word
        spread.speech(1.5); spread.silence(0.8); spread.speech(1.0); spread.silence(2)
        var spreadChunker = DictationPauseChunker()
        let spreadEvents = breezeFeed(spread.samples, blockSize: 1_600, into: &spreadChunker)
        assertFalse(spreadEvents.contains { $0.kind == .commit }, "2.5 s of speech in 5 s of audio doesn't commit")
        breezeAssertCutsInSilence(spreadEvents, spread, "1.5 s + 1 s of speech")
    }

    runSuite("Pause chunker: a 0.3-0.5 s pause speculates on the piece so far, and the next speculation keeps its start with a later end") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4); take.silence(0.4)
        take.speech(2); take.silence(0.4)
        var chunker = DictationPauseChunker()
        let events = breezeFeed(take.samples, blockSize: 1_600, into: &chunker)
        assertFalse(events.contains { $0.kind == .commit }, "no 0.5 s pause, no commit")
        let firstPause = take.speechRanges[0].upperBound...take.speechRanges[1].lowerBound
        let secondPause = take.speechRanges[1].upperBound...take.count
        let first = events.filter { $0.kind == .speculate && firstPause.contains($0.end) }
        let second = events.filter { $0.kind == .speculate && secondPause.contains($0.end) }
        assertFalse(first.isEmpty, "the first short pause speculates")
        assertFalse(second.isEmpty, "the second short pause speculates")
        assertTrue((first + second).allSatisfy { $0.start == 0 }, "both cover the same piece from its start")
        if let firstEnd = first.map(\.end).max(), let secondEnd = second.map(\.end).min() {
            assertTrue(secondEnd > firstEnd, "the later speculation ends later")
        }
        assertEqual(chunker.pieceStart, 0)
        breezeAssertCutsInSilence(events, take, "short pauses")
    }

    runSuite("Pause chunker: the same audio in any block size gives the same events") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4); take.silence(0.4)
        take.speech(3.5); take.silence(0.7)
        take.speech(1); take.silence(1.2)
        take.speech(5); take.silence(0.35)
        take.speech(3)
        var reference = DictationPauseChunker()
        let expected = reference.append(take.samples)
        assertTrue(expected.contains { $0.kind == .commit } && expected.contains { $0.kind == .speculate },
                   "the take exercises both kinds of event")
        for blockSize in [1, 160, 333, 4_096] {
            var chunker = DictationPauseChunker()
            let events = breezeFeed(take.samples, blockSize: blockSize, into: &chunker)
            assertEqual(events, expected, "block size \(blockSize)")
            assertEqual(chunker.pieceStart, reference.pieceStart, "block size \(blockSize)")
            assertEqual(chunker.lastSpeechEnd, reference.lastSpeechEnd, "block size \(blockSize)")
        }
        breezeAssertCutsInSilence(expected, take, "mixed take")
    }

    runSuite("Pause chunker: a take that starts straight into speech still commits after its first 3 s of speech") {
        // No lead-in silence: the person was already talking when the take began.
        var take = BreezeTestTake()
        take.speech(4.5); take.silence(0.8)
        take.speech(4.5); take.silence(0.8)
        var chunker = DictationPauseChunker()
        let events = breezeFeed(take.samples, blockSize: 1_600, into: &chunker)
        let commits = events.filter { $0.kind == .commit }
        assertEqual(commits.count, 2, "one commit per pause after 4.5 s of speech (3.6 s voiced)")
        if let first = commits.first {
            assertTrue(first.end <= take.speechRanges[1].lowerBound, "the first piece is cut in the first pause")
        }
        breezeAssertCutsInSilence(events, take, "no lead-in")
    }

    runSuite("Pause chunker: a steady voice with few pauses is still speech, so cuts never land inside it") {
        // Same promises as above, but the voice has no dips between words and
        // pauses are under a fifth of the take.
        var steady = BreezeTestTake()
        steady.steadySpeech(4); steady.silence(0.8)
        steady.steadySpeech(4); steady.silence(0.8)
        steady.steadySpeech(4); steady.silence(0.8)
        var chunker = DictationPauseChunker()
        let events = breezeFeed(steady.samples, blockSize: 1_600, into: &chunker)
        assertEqual(events.filter { $0.kind == .commit }.count, 3, "one commit per 0.8 s pause after 4 s of speech")
        assertNotNil(chunker.lastSpeechEnd, "4 s of RMS 0.07 is speech")
        breezeAssertCutsInSilence(events, steady, "steady three pieces")

        var mixed = BreezeTestTake()
        mixed.steadySpeech(4); mixed.silence(0.4)
        mixed.steadySpeech(3.5); mixed.silence(0.7)
        mixed.steadySpeech(1); mixed.silence(1.2)
        mixed.steadySpeech(5); mixed.silence(0.35)
        mixed.steadySpeech(3)
        var mixedChunker = DictationPauseChunker()
        breezeAssertCutsInSilence(mixedChunker.append(mixed.samples), mixed, "steady mixed take")
    }

    runSuite("Pause chunker: speech past 25 s commits at the next 0.3 s pause") {
        var long = BreezeTestTake()
        long.silence(0.5) // the moment before the first word
        long.speech(26); long.silence(0.4)
        long.speech(4); long.silence(0.4)
        var chunker = DictationPauseChunker()
        let events = breezeFeed(long.samples, blockSize: 1_600, into: &chunker)
        let commits = events.filter { $0.kind == .commit }
        assertEqual(commits.count, 1, "only the long piece commits on a short pause")
        if let commit = commits.first {
            assertEqual(commit.start, 0)
            assertTrue(commit.end > long.speechRanges[0].upperBound && commit.end <= long.speechRanges[1].lowerBound,
                       "the long piece is cut in the first short pause")
        }
        breezeAssertCutsInSilence(events, long, commitPause: 0.3, "26 s piece")

        var control = BreezeTestTake()
        control.silence(0.5) // the moment before the first word
        control.speech(20); control.silence(0.4); control.speech(1)
        var controlChunker = DictationPauseChunker()
        let controlEvents = breezeFeed(control.samples, blockSize: 1_600, into: &controlChunker)
        assertFalse(controlEvents.contains { $0.kind == .commit }, "a 20 s piece waits for a 0.5 s pause")
    }

    runSuite("Pause chunker: background noise alone yields no events") {
        var noise = BreezeTestTake()
        noise.silence(10)
        for (label, samples) in [("faint noise", noise.samples), ("zeros", [Float](repeating: 0, count: breezeSamples(10)))] {
            var chunker = DictationPauseChunker()
            let events = breezeFeed(samples, blockSize: 1_600, into: &chunker)
            assertTrue(events.isEmpty, "\(label): no events, got \(events)")
            assertNil(chunker.lastSpeechEnd, "\(label): no speech")
            assertEqual(chunker.receivedSamples, samples.count)
        }
    }

    // B. Prompt and language

    runSuite("Breeze prompt starts with the style sample and ends with the preceding text") {
        assertEqual(BreezeDictationPrompt.make(dictionary: [], precedingText: ""), BreezeDictationPrompt.styleSample)
        let prompt = BreezeDictationPrompt.make(
            dictionary: [CustomDictionaryEntry(spoken: "кубер", replacement: "Kubernetes")],
            precedingText: "Привет, это заметка про деплой."
        )
        assertTrue(prompt.hasPrefix(BreezeDictationPrompt.styleSample))
        assertTrue(prompt.hasSuffix("Привет, это заметка про деплой."))
        let withoutText = BreezeDictationPrompt.make(
            dictionary: [CustomDictionaryEntry(spoken: "кубер", replacement: "Kubernetes")], precedingText: ""
        )
        assertTrue(withoutText.hasPrefix(BreezeDictationPrompt.styleSample))
    }

    runSuite("Breeze prompt terms: only Latin replacements, no emails, none over 32 characters, no duplicates, at most 240 characters") {
        let thirtyTwo = "Q" + String(repeating: "w", count: 31)
        let thirtyThree = "Z" + String(repeating: "k", count: 32)
        let dictionary = [
            CustomDictionaryEntry(spoken: "кубер", replacement: "Kubernetes"),
            CustomDictionaryEntry(spoken: "кубернетис", replacement: "kubernetes"),
            CustomDictionaryEntry(spoken: "кубы", replacement: "KUBERNETES"),
            CustomDictionaryEntry(spoken: "звонок", replacement: "созвонище"),
            CustomDictionaryEntry(spoken: "почта", replacement: "me@example.com"),
            CustomDictionaryEntry(spoken: "длинное", replacement: thirtyTwo),
            CustomDictionaryEntry(spoken: "слишком длинное", replacement: thirtyThree),
            CustomDictionaryEntry(spoken: "графана", replacement: "Grafana Cloud"),
        ]
        let terms = BreezeDictationPrompt.latinTerms(from: dictionary)
        let lowered = terms.lowercased()
        assertEqual(lowered.components(separatedBy: "kubernetes").count - 1, 1, "duplicates appear once: \(terms)")
        assertTrue(terms.contains("Grafana Cloud"))
        assertTrue(terms.contains(thirtyTwo), "32 characters is still a term")
        assertFalse(terms.contains("созвонище"), "Cyrillic-only replacements are left out")
        assertFalse(terms.contains("@"), "emails are left out")
        assertFalse(terms.contains(thirtyThree), "over 32 characters is left out")

        let prompt = BreezeDictationPrompt.make(dictionary: dictionary, precedingText: "")
        assertTrue(prompt.lowercased().contains("kubernetes"), "the prompt carries the terms")
        assertFalse(prompt.contains("me@example.com"))

        let many = (0..<80).map { CustomDictionaryEntry(spoken: "термин \($0)", replacement: "TermNumber\($0)Alpha") }
        let manyTerms = BreezeDictationPrompt.latinTerms(from: many)
        assertFalse(manyTerms.isEmpty)
        assertTrue(manyTerms.count <= 240, "joined terms are \(manyTerms.count) characters")
    }

    runSuite("Breeze prompt keeps the last maximumPrecedingCharacters of the preceding text, cut at a word boundary") {
        let words = ["Kubernetes", "и", "деплой", "a", "длинноесловодлинное", "push", "на", "stage,", "потом", "rebase."]
        var base = "НАЧАЛО"
        var index = 0
        while base.count < 420 {
            base += " " + words[index % words.count]
            index += 1
        }
        for trim in 0..<40 {
            let text = String(base.prefix(base.count - trim))
            let kept = BreezeDictationPrompt.tail(of: text, maximumCharacters: BreezeDictationPrompt.maximumPrecedingCharacters)
            assertFalse(kept.isEmpty, "trim \(trim): something is kept")
            assertTrue(kept.count <= BreezeDictationPrompt.maximumPrecedingCharacters, "trim \(trim): kept \(kept.count) characters")
            // Trailing whitespace is trimmed off first, so compare with the text without it.
            let original = String(text.reversed().drop(while: \.isWhitespace).reversed())
            assertTrue(original.hasSuffix(kept), "trim \(trim): kept part is a suffix")
            let cut = original.count - kept.count
            if cut > 0, let first = kept.first {
                let before = original[original.index(original.startIndex, offsetBy: cut - 1)]
                assertFalse(before.isLetter && first.isLetter, "trim \(trim): starts mid-word: \(kept.prefix(12))")
            }
            let prompt = BreezeDictationPrompt.make(dictionary: [], precedingText: text)
            assertTrue(prompt.hasSuffix(kept), "trim \(trim): the prompt ends with the kept part")
            assertFalse(prompt.contains("НАЧАЛО"), "trim \(trim): the old beginning is dropped")
        }
        assertEqual(BreezeDictationPrompt.tail(of: "привет мир", maximumCharacters: 200), "привет мир")
    }

    runSuite("Breeze language: an explicit meeting language wins, else the single non-English user language") {
        typealias Lang = BreezeDictationLanguage
        assertEqual(Lang.code(userLanguageCodes: ["ru-RU", "en-US"], explicitMeetingLanguage: "de"), "de")
        assertEqual(Lang.code(userLanguageCodes: ["ru-RU", "en-US", "en", "ru"], explicitMeetingLanguage: nil), "ru")
        assertEqual(Lang.code(userLanguageCodes: ["en-US", "en-GB", "en"], explicitMeetingLanguage: nil), "en")
        assertNil(Lang.code(userLanguageCodes: ["ru", "de-DE", "en"], explicitMeetingLanguage: nil))
        assertEqual(Lang.code(userLanguageCodes: ["zh_Hans", "zh-Hant-TW", "en"], explicitMeetingLanguage: nil), "zh")
        assertEqual(Lang.code(userLanguageCodes: ["ru_RU", "ru-RU"], explicitMeetingLanguage: nil), "ru")
    }

    // C. Install check

    runSuite("Breeze counts as installed only with the marker, the Core ML encoder and full-size weights") {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.standardizedFileURL
        let root = tempRoot.appendingPathComponent("BreezeDictationTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            // Only ever delete our own folder under the temp directory.
            if root.standardizedFileURL.path.hasPrefix(tempRoot.path + "/") {
                try? fileManager.removeItem(at: root)
            }
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            assertFalse(BreezeModelInstall.isInstalled(modelsRoot: root, fileManager: fileManager), "empty root")

            let folder = BreezeModelInstall.directory(modelsRoot: root)
            let encoder = folder.appendingPathComponent(BreezeModelInstall.coreMLEncoderDirectoryName, isDirectory: true)
            try fileManager.createDirectory(at: encoder.appendingPathComponent("weights"), withIntermediateDirectories: true)
            try Data([1]).write(to: encoder.appendingPathComponent("coremldata.bin"))
            try Data([1]).write(to: encoder.appendingPathComponent("weights/weight.bin"))

            let weights = BreezeModelInstall.weightsURL(modelsRoot: root)
            func setWeightsSize(_ bytes: Int64) throws {
                if !fileManager.fileExists(atPath: weights.path) {
                    _ = fileManager.createFile(atPath: weights.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: weights)
                try handle.truncate(atOffset: UInt64(bytes)) // sparse, no real disk use
                try handle.close()
            }

            try setWeightsSize(BreezeModelInstall.minimumWeightsBytes)
            assertFalse(BreezeModelInstall.isInstalled(modelsRoot: root, fileManager: fileManager), "no marker")

            try Data("{}".utf8).write(to: folder.appendingPathComponent(BreezeModelInstall.markerFileName))
            try setWeightsSize(BreezeModelInstall.minimumWeightsBytes - 1)
            assertFalse(BreezeModelInstall.isInstalled(modelsRoot: root, fileManager: fileManager), "weights too small")

            try setWeightsSize(BreezeModelInstall.minimumWeightsBytes)
            assertTrue(BreezeModelInstall.isInstalled(modelsRoot: root, fileManager: fileManager), "everything present")
        } catch {
            recordFailure("couldn't build the fake install: \(error)")
        }
    }

    // D. Model picker

    runSuite("The model picker hides Breeze until it is installed, but never while it is selected") {
        let parakeetInstalled: (ParakeetModelVariant) -> Bool = { _ in true }
        let parakeetMissing: (ParakeetModelVariant) -> Bool = { _ in false }
        for parakeet in [parakeetInstalled, parakeetMissing] {
            assertFalse(TranscriptionModelVisibilityPolicy.isVisible(
                .breezeASR25, selectedModel: .parakeetTDTv3, isLocallyInstalled: parakeet, isBreezeInstalled: { false }
            ), "hidden while not installed")
            assertTrue(TranscriptionModelVisibilityPolicy.isVisible(
                .breezeASR25, selectedModel: .parakeetTDTv3, isLocallyInstalled: parakeet, isBreezeInstalled: { true }
            ), "shown once installed")
            assertTrue(TranscriptionModelVisibilityPolicy.isVisible(
                .breezeASR25, selectedModel: .breezeASR25, isLocallyInstalled: parakeet, isBreezeInstalled: { false }
            ), "a selected model stays listed")
        }
        assertTrue(TranscriptionModelChoice.breezeASR25.isLocalInstallOnly)
        assertTrue(TranscriptionModelChoice.breezeASR25.isWhisper)
        assertTrue(TranscriptionModelChoice.breezeASR25.usesWhisperCpp)
    }

    // E. Live dictation

    await runSuite("Live Breeze: finish returns the pieces' texts in audio order, with the init language and earlier pieces in later prompts") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4.5, amplitude: 0.08); take.silence(0.8)
        take.speech(4, amplitude: 0.14); take.silence(0.8)
        take.speech(4.5, amplitude: 0.11); take.silence(0.8)
        let fake = BreezeTestTranscriber()
        let live = await breezeStartLive(take, fake: fake) { calls in calls.contains { $0.amplitudeTag == breezeTagC } }
        guard let texts = await live.finish(fullSampleCount: take.count) else {
            recordFailure("finish returned nil for a clean take")
            return
        }
        assertTrue(texts.count >= 2, "at least two pieces: \(texts)")
        let speechTags = texts.compactMap { fake.amplitudeTag(ofText: $0) }.filter { $0 > 1 }
        assertEqual(speechTags, [breezeTagA, breezeTagB, breezeTagC], "pieces in audio order: \(texts)")

        let calls = fake.calls
        assertTrue(calls.allSatisfy { $0.language == "ru" }, "every call gets the init language")
        if texts.count >= 2 {
            for call in calls where call.amplitudeTag == breezeTagB {
                assertTrue(call.prompt.contains(texts[0]), "piece 2's prompt carries piece 1's text: \(call.prompt)")
            }
            for call in calls where call.amplitudeTag == breezeTagC {
                assertTrue(call.prompt.contains(texts[0]) && call.prompt.contains(texts[1]),
                           "piece 3's prompt carries pieces 1 and 2: \(call.prompt)")
            }
        }
    }

    await runSuite("Live Breeze: a take ending in 0.3 s of silence reuses the last speculation instead of transcribing again") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4.5, amplitude: 0.08); take.silence(0.8)
        take.speech(6, amplitude: 0.14); take.silence(0.4)
        let fake = BreezeTestTranscriber()
        let lastPieceMinimum = breezeSamples(6.3) - breezeTestFrame
        let live = await breezeStartLive(take, fake: fake) { calls in
            calls.contains { $0.amplitudeTag == breezeTagB && $0.sampleCount >= lastPieceMinimum }
        }
        let callsBeforeFinish = fake.calls.count
        let texts = await live.finish(fullSampleCount: take.count)
        assertEqual(fake.calls.count, callsBeforeFinish, "finish made no new transcription call")
        assertNotNil(texts)
        let tags = (texts ?? []).compactMap { fake.amplitudeTag(ofText: $0) }.filter { $0 > 1 }
        assertEqual(tags, [breezeTagA, breezeTagB])
    }

    await runSuite("Live Breeze: a take that stops mid-speech transcribes just the tail on finish") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4.5, amplitude: 0.08); take.silence(0.8)
        take.speech(4, amplitude: 0.14)
        let fake = BreezeTestTranscriber()
        let live = await breezeStartLive(take, fake: fake) { calls in calls.contains { $0.amplitudeTag == breezeTagA } }
        let callsBeforeFinish = fake.calls.count
        let texts = await live.finish(fullSampleCount: take.count)
        assertEqual(fake.calls.count, callsBeforeFinish + 1, "exactly one call for the tail")
        assertEqual(fake.calls.last?.amplitudeTag, breezeTagB, "the tail call is the last speech")
        let tags = (texts ?? []).compactMap { fake.amplitudeTag(ofText: $0) }.filter { $0 > 1 }
        assertEqual(tags, [breezeTagA, breezeTagB])
    }

    await runSuite("Live Breeze: a click or breath after the last committed piece is not transcribed as a tail") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4.5, amplitude: 0.08); take.silence(0.8)
        take.steadySpeech(0.1, amplitude: 0.14) // the Stop key's click, 5 frames
        let fake = BreezeTestTranscriber()
        let live = await breezeStartLive(take, fake: fake) { calls in calls.contains { $0.amplitudeTag == breezeTagA } }
        let callsBeforeFinish = fake.calls.count
        let texts = await live.finish(fullSampleCount: take.count)
        assertEqual(fake.calls.count, callsBeforeFinish, "no call for the click")
        let tags = (texts ?? []).compactMap { fake.amplitudeTag(ofText: $0) }.filter { $0 > 1 }
        assertEqual(tags, [breezeTagA], "only the committed piece")
    }

    await runSuite("Live Breeze: finish gives up when the full take length differs from what it heard by more than 0.3 s") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4.5, amplitude: 0.08); take.silence(0.8)
        take.speech(4, amplitude: 0.14); take.silence(0.8)
        for (offset, expectResult) in [(4_801, false), (-4_801, false), (4_800, true)] {
            let fake = BreezeTestTranscriber()
            let live = await breezeStartLive(take, fake: fake) { calls in calls.contains { $0.amplitudeTag == breezeTagB } }
            let texts = await live.finish(fullSampleCount: take.count + offset)
            assertEqual(texts != nil, expectResult, "length off by \(offset) samples")
        }
    }

    await runSuite("Live Breeze: finish returns nil if any piece fails to transcribe") {
        var committed = BreezeTestTake()
        committed.silence(0.5) // the moment before the first word
        committed.speech(4.5, amplitude: 0.08); committed.silence(0.8)
        committed.speech(4, amplitude: 0.14); committed.silence(0.8)
        let failsFirst = BreezeTestTranscriber(failsFor: { $0 == breezeTagA })
        let live = await breezeStartLive(committed, fake: failsFirst) { calls in
            calls.contains { $0.amplitudeTag == breezeTagA }
        }
        assertNil(await live.finish(fullSampleCount: committed.count), "a failed live piece")

        var midSpeech = BreezeTestTake()
        midSpeech.silence(0.5) // the moment before the first word
        midSpeech.speech(4.5, amplitude: 0.08); midSpeech.silence(0.8)
        midSpeech.speech(4, amplitude: 0.14)
        let failsTail = BreezeTestTranscriber(failsFor: { $0 == breezeTagB })
        let tailLive = await breezeStartLive(midSpeech, fake: failsTail) { calls in
            calls.contains { $0.amplitudeTag == breezeTagA }
        }
        assertNil(await tailLive.finish(fullSampleCount: midSpeech.count), "a failed tail piece")
    }

    await runSuite("Live Breeze: after cancel no more transcription calls are made") {
        var take = BreezeTestTake()
        take.silence(0.5) // the moment before the first word
        take.speech(4.5, amplitude: 0.08); take.silence(0.8)
        take.speech(4, amplitude: 0.14); take.silence(0.8)

        let neverStarted = BreezeTestTranscriber()
        let cancelledEarly = BreezeLiveDictation(transcriber: neverStarted, language: "ru", prompt: { $0 })
        cancelledEarly.start()
        cancelledEarly.cancel()
        cancelledEarly.sink.append(take.samples, sampleRate: 16_000)
        _ = await breezeWait(polls: 15) { !neverStarted.calls.isEmpty }
        assertEqual(neverStarted.calls.count, 0, "cancelled before any audio")

        var firstHalf = BreezeTestTake()
        firstHalf.silence(0.5) // the moment before the first word
        firstHalf.speech(4.5, amplitude: 0.08); firstHalf.silence(0.8)
        let fake = BreezeTestTranscriber()
        let live = await breezeStartLive(firstHalf, fake: fake) { calls in calls.contains { $0.amplitudeTag == breezeTagA } }
        live.cancel()
        let callsAtCancel = fake.calls.count
        var secondHalf = BreezeTestTake()
        secondHalf.speech(4, amplitude: 0.14); secondHalf.silence(0.8)
        live.sink.append(secondHalf.samples, sampleRate: 16_000)
        _ = await breezeWait(polls: 15) { fake.calls.count > callsAtCancel }
        assertEqual(fake.calls.count, callsAtCancel, "cancelled after the first piece")
    }
}
