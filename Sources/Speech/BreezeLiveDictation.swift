// BreezeLiveDictation.swift
// Fork: one dictation take that Breeze transcribes in pieces while it
// records, so at Stop only the last piece is left. WhisperEngine starts one
// per Breeze take (`beginLiveDictation`) and asks it for the text at Stop;
// any doubt (lost audio, a failed piece, a cancelled take) returns nil and the
// whole take is transcribed in one call, exactly as before.

import Foundation

final class BreezeLiveDictation: @unchecked Sendable {
    /// Fed by the capture queues next to the recording spool
    /// (`STTRouter.setDictationChunkSink`); read every 100 ms here. 60 s of
    /// unread audio means the pump stalled, and the duration check at Stop
    /// then falls back to the whole take.
    let sink = DictationPreviewSampleSink(capacitySeconds: 60)

    private struct Piece: Hashable {
        let start: Int
        let end: Int
    }

    private let transcriber: any BreezePieceTranscribing
    private let language: String?
    private let prompt: @Sendable (_ precedingText: String) -> String
    private let cancellation = WhisperCppCancellation()
    private let wake: AsyncStream<Void>.Continuation
    private let wakes: AsyncStream<Void>

    private static let sampleRate = 16_000
    private static let frameSamples = Int(DictationPauseChunker.frameSeconds * Double(sampleRate))
    private static let pumpInterval: Duration = .milliseconds(100)
    /// The live feed and the Stop snapshot are resampled by different
    /// converters, so their lengths differ by a few milliseconds; more than
    /// this means audio went missing (or arrived before the feed was attached).
    private static let durationTolerance = Int(0.3 * Double(sampleRate))
    /// A tail after the committed pieces with less speech than this (0.16 s)
    /// is a breath, a cough or the Stop key's click. Whisper fed that with a
    /// prompt tends to echo the prompt, so it's left out.
    static let minimumTailSpeechFrames = 8

    private let lock = NSLock()
    // Everything below is guarded by `lock`.
    private var chunker = DictationPauseChunker()
    /// Audio from `audioOffset` on, as long as a queued or future piece needs it.
    private var audio: [Float] = []
    private var audioOffset = 0
    private var queued: [Piece] = []
    private var running: Piece?
    /// Stops the running piece alone, when Stop no longer needs it.
    private var runningCancellation: WhisperCppCancellation?
    private var texts: [Piece: String] = [:]
    /// Pieces that end up in the take's text, in order.
    private var committed: [Piece] = []
    private var latestSpeculation: Piece?
    private var failed = false
    private var reusedSpeculation = false

    private var pumpTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?

    init(
        transcriber: any BreezePieceTranscribing,
        language: String?,
        prompt: @escaping @Sendable (_ precedingText: String) -> String
    ) {
        self.transcriber = transcriber
        self.language = language
        self.prompt = prompt
        (wakes, wake) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
    }

    func start() {
        workerTask = Task.detached(priority: .userInitiated) { [weak self, wakes] in
            for await _ in wakes {
                while let self, let piece = self.nextPiece() {
                    await self.transcribe(piece)
                }
            }
        }
        pumpTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pumpInterval)
                guard let self else { return }
                self.feed(self.sink.take())
            }
        }
    }

    /// Esc, a failed start, or a new take: stop everything, keep nothing.
    func cancel() {
        cancellation.cancel()
        lock.withLock { runningCancellation }?.cancel()
        pumpTask?.cancel()
        workerTask?.cancel()
        wake.finish()
    }

    /// The take's text as pieces in order, or nil when the whole take must be
    /// transcribed instead. `fullSampleCount` is the Stop snapshot's length at
    /// 16 kHz, the audio that whole-take transcription would read.
    func finish(fullSampleCount: Int) async -> [String]? {
        pumpTask?.cancel()
        await pumpTask?.value
        // The microphone is already stopped: this drains the last of the take.
        feed(sink.take())

        let tail: Piece? = lock.withLock {
            guard !failed, abs(chunker.receivedSamples - fullSampleCount) <= Self.durationTolerance else {
                failed = true
                return nil
            }
            let pieceStart = chunker.pieceStart
            guard let lastSpeechEnd = chunker.lastSpeechEnd, lastSpeechEnd > pieceStart else { return nil }
            if !committed.isEmpty, chunker.pieceSpeechFrames < Self.minimumTailSpeechFrames { return nil }
            if let speculation = latestSpeculation, speculation.start == pieceStart, speculation.end >= lastSpeechEnd {
                // They stopped talking a moment before Stop: this piece may be done already.
                reusedSpeculation = true
                return speculation
            }
            let piece = Piece(start: pieceStart, end: chunker.receivedSamples)
            queued.append(piece)
            return piece
        }
        let needed = lock.withLock { () -> [Piece]? in
            guard !failed else { return nil }
            let pieces = committed + (tail.map { [$0] } ?? [])
            // Speculations nobody needs any more would only delay the tail.
            queued.removeAll { !pieces.contains($0) }
            if let running, !pieces.contains(running) { runningCancellation?.cancel() }
            return pieces
        }
        guard let needed else {
            cancel()
            return nil
        }
        wake.yield()

        while true {
            if Task.isCancelled {
                cancel()
                return nil
            }
            let outcome: [String]?? = lock.withLock {
                if failed { return .some(nil) }
                let done = needed.compactMap { texts[$0] }
                // An empty piece (noise between words) would leave a double space.
                return done.count == needed.count ? .some(done.filter { !$0.isEmpty }) : nil
            }
            if let outcome {
                cancel()
                return outcome
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Piece count and whether the speculative tail was reused; counts only.
    var summary: (pieces: Int, reusedSpeculation: Bool) {
        lock.withLock { (committed.count + (reusedSpeculation ? 1 : 0), reusedSpeculation) }
    }

    // MARK: - Feeding

    private func feed(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let woke: Bool = lock.withLock {
            audio.append(contentsOf: samples)
            var queuedAny = false
            // One 20 ms frame at a time, so `chunker.lastSpeechEnd` is the end
            // of speech as of each event, not speech later in the same read.
            var offset = 0
            while offset < samples.count {
                let next = min(offset + Self.frameSamples, samples.count)
                for event in chunker.append(Array(samples[offset..<next])) {
                    queuedAny = handle(event) || queuedAny
                }
                offset = next
            }
            return queuedAny
        }
        if woke { wake.yield() }
    }

    /// Under `lock`. Returns true when a piece was queued.
    private func handle(_ event: DictationPauseChunker.Event) -> Bool {
        let piece = Piece(start: event.start, end: event.end)
        switch event.kind {
        case .speculate:
            // A newer speculation for the same piece replaces one that hasn't started.
            queued.removeAll { $0.start == piece.start && !committed.contains($0) }
            queued.append(piece)
            latestSpeculation = piece
            return true
        case .commit:
            defer { latestSpeculation = nil }
            // Reuse the speculation only if it already covers every word of the
            // piece. A long piece commits at a short pause with no fresh
            // speculation, and an older one would lose the words after it.
            if let speculation = latestSpeculation, speculation.start == piece.start,
               speculation.end >= (chunker.lastSpeechEnd ?? 0) {
                committed.append(speculation)
                return false
            }
            committed.append(piece)
            queued.append(piece)
            return true
        }
    }

    // MARK: - Worker

    private func nextPiece() -> Piece? {
        lock.withLock {
            guard !failed, !queued.isEmpty else { return nil }
            let piece = queued.removeFirst()
            running = piece
            runningCancellation = WhisperCppCancellation()
            return piece
        }
    }

    private func transcribe(_ piece: Piece) async {
        let input: (samples: [Float], preceding: String)? = lock.withLock {
            let lower = piece.start - audioOffset
            let upper = min(piece.end - audioOffset, audio.count)
            guard lower >= 0, lower < upper else { return nil }
            let preceding = committed
                .filter { $0.end <= piece.start }
                .compactMap { texts[$0] }
                .joined(separator: " ")
            return (Array(audio[lower..<upper]), preceding)
        }
        guard let input, let pieceCancellation = lock.withLock({ runningCancellation }) else {
            lock.withLock { failed = true; running = nil; runningCancellation = nil }
            return
        }
        // The take's cancellation reaches the piece through its own token.
        if cancellation.isCancelled { pieceCancellation.cancel() }
        do {
            let text = try await transcriber.transcribe(
                input.samples,
                language: language,
                prompt: prompt(input.preceding),
                cancellation: pieceCancellation
            )
            lock.withLock {
                texts[piece] = text
                running = nil
                runningCancellation = nil
                trimAudio()
            }
        } catch {
            lock.withLock {
                running = nil
                runningCancellation = nil
                // A speculation Stop dropped (its own token, take still on) is
                // simply gone. A cancelled take is dropped by its owner; any
                // other failure sends the take to whole-take transcription.
                let dropped = pieceCancellation.isCancelled && !cancellation.isCancelled
                if !dropped { failed = true }
            }
        }
    }

    /// Under `lock`. Drops audio no queued, running or future piece can need,
    /// so an hour-long take doesn't keep a second copy of itself.
    private func trimAudio() {
        var needed = chunker.pieceStart
        for piece in queued { needed = min(needed, piece.start) }
        if let running { needed = min(needed, running.start) }
        if let latestSpeculation { needed = min(needed, latestSpeculation.start) }
        let drop = needed - audioOffset
        guard drop > 0, drop <= audio.count else { return }
        audio.removeFirst(drop)
        audioOffset = needed
    }
}
