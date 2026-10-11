import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// What the meeting LLM pass asks of the model. The fork's transcript LLM
/// (`Sources/TranscriptLLM/`) implements it; this module only knows the
/// protocol.
@MainActor
protocol MeetingUtteranceRefiner: AnyObject, Sendable {
    /// Written into the transcript's `transcript_llm` marker.
    var meetingRefinerModelID: String { get }
    func refineMeetingUtterance(_ text: String) async -> MeetingUtteranceRefinement
}

enum MeetingUtteranceRefinement: Equatable, Sendable {
    case refined(String)
    /// The answer was rejected or the engine failed on this utterance: keep
    /// its text and move on.
    case keep
    /// The model isn't ready (downloading, starting, restarting): pause the
    /// job and try again later.
    case unavailable
}

/// A queued meeting, saved to disk before any work starts and after every
/// few utterances, so a quit, crash or power loss resumes where it stopped
/// instead of losing the work or the queue.
struct MeetingTranscriptLLMJob: Codable, Equatable, Sendable {
    var version = 1
    let captureID: String
    var transcriptPath: String
    let enqueuedAt: Date
    /// Utterance index (as a string, for JSON) → text to write.
    var results: [String: String] = [:]
    /// Utterance index → the text the result was made from. The commit
    /// replaces an utterance only while the transcript still says this.
    var originals: [String: String] = [:]
}

/// The pass's files: `<state>/meeting-llm/<capture id>.json` per queued
/// meeting, and `originals/` with the transcript as it was before each
/// rewrite. Owner-only, like the rest of `state/`.
struct MeetingTranscriptLLMJobStore: Sendable {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.transcriptedStateDir.appendingPathComponent("meeting-llm", isDirectory: true)
    }

    var originalsDirectory: URL { directory.appendingPathComponent("originals", isDirectory: true) }

    func jobURL(for captureID: String) -> URL {
        directory.appendingPathComponent("\(Self.fileSafe(captureID)).json", isDirectory: false)
    }

    func save(_ job: MeetingTranscriptLLMJob) throws {
        try FileManager.default.createPrivateDirectory(at: directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = jobURL(for: job.captureID)
        try encoder.encode(job).write(to: url, options: .atomic)
        FileManager.default.restrictFileToOwnerOnly(at: url)
    }

    func load(_ captureID: String) -> MeetingTranscriptLLMJob? {
        decode(jobURL(for: captureID))
    }

    /// Every queued job, oldest first. A file that won't decode is left alone
    /// (never deleted on a guess) and skipped.
    func all() -> [MeetingTranscriptLLMJob] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap(decode)
            .sorted { $0.enqueuedAt < $1.enqueuedAt }
    }

    func remove(_ captureID: String) {
        try? FileManager.default.removeItem(at: jobURL(for: captureID))
    }

    /// Copies the transcript as it is right before the rewrite. The rewrite
    /// waits for this to succeed.
    @discardableResult
    func backupOriginal(_ markdown: String, captureID: String, at date: Date = Date()) throws -> URL {
        try FileManager.default.createPrivateDirectory(at: originalsDirectory)
        let stamp = Int(date.timeIntervalSince1970)
        let url = originalsDirectory.appendingPathComponent("\(Self.fileSafe(captureID))-\(stamp).md", isDirectory: false)
        try Data(markdown.utf8).write(to: url, options: .atomic)
        FileManager.default.restrictFileToOwnerOnly(at: url)
        return url
    }

    private func decode(_ url: URL) -> MeetingTranscriptLLMJob? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let job = try? decoder.decode(MeetingTranscriptLLMJob.self, from: data),
              job.version == 1 else { return nil }
        return job
    }

    static func fileSafe(_ id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return safe.isEmpty ? "meeting" : safe
    }
}

/// The meeting side of the transcript LLM (fork): after a meeting's
/// transcript is saved and restyled, every utterance goes through the model
/// with the meeting prompt (`TranscriptLLMPromptPreference.meeting`), and
/// the corrected text replaces the utterance in place. Timestamps, speaker
/// labels, frontmatter and every other section are untouched.
///
/// Nothing here can lose a transcript:
/// - the job is on disk before work starts and checkpointed as it goes;
/// - the transcript is rewritten once, at the end, atomically, after a copy
///   of it is saved to `originals/`; if that copy fails, nothing is written;
/// - an utterance the user (or anything else) changed meanwhile is skipped;
/// - an answer the policy rejects keeps the recognized text;
/// - a model that isn't ready pauses the job; a deleted transcript drops it.
///
/// Long meetings are fine: one request per utterance, so the 16k-token
/// context never limits the meeting's length, and the helper serves meetings
/// on their own slot so a dictation never waits behind one.
actor MeetingTranscriptLLMWorker {
    static let shared = MeetingTranscriptLLMWorker()

    /// Utterances shorter than this ("да", "okay") keep their text: too
    /// little context for the model to improve, and most of a long meeting.
    static let minimumWords = 3
    static let checkpointEvery = 20
    static let pausedRetryDelay: Duration = .seconds(60)

    private var refiner: MeetingUtteranceRefiner?
    /// Resolved on first use, not at init: building the default path creates
    /// the app's state folder, which a test's worker must never touch.
    private var configuredStore: MeetingTranscriptLLMJobStore?
    private var store: MeetingTranscriptLLMJobStore {
        if let configuredStore { return configuredStore }
        let fallback = MeetingTranscriptLLMJobStore(directory: MeetingTranscriptLLMJobStore.defaultDirectory)
        configuredStore = fallback
        return fallback
    }
    private var running: Task<Void, Never>?
    private var onTranscriptChanged: @Sendable (URL) -> Void = { _ in }
    private var log: @Sendable (String) -> Void = { _ in }

    init() {}

    /// Called once at launch. Resumes whatever an earlier run left queued.
    func configure(
        refiner: MeetingUtteranceRefiner,
        store: MeetingTranscriptLLMJobStore? = nil,
        onTranscriptChanged: @escaping @Sendable (URL) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.refiner = refiner
        if let store { configuredStore = store }
        self.onTranscriptChanged = onTranscriptChanged
        self.log = log
        startIfNeeded()
    }

    /// Queues a freshly saved transcript. Skips one already rewritten.
    func enqueue(transcriptURL: URL) {
        guard let markdown = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !MeetingTranscriptLLMDocument.isProcessed(markdown) else { return }
        let captureID = MeetingTranscriptLLMDocument.captureID(in: markdown)
            ?? transcriptURL.deletingPathExtension().lastPathComponent
        if var existing = store.load(captureID) {
            existing.transcriptPath = transcriptURL.path
            try? store.save(existing)
        } else {
            do {
                try store.save(MeetingTranscriptLLMJob(
                    captureID: captureID, transcriptPath: transcriptURL.path, enqueuedAt: Date()
                ))
            } catch {
                log("MEETING LLM | couldn't queue a transcript: \(error.localizedDescription)")
                return
            }
        }
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard running == nil, refiner != nil else { return }
        running = Task { await self.drain() }
    }

    private func drain() async {
        // Jobs finished in this round. One that is still on disk afterwards
        // (its file couldn't be removed) waits a round instead of spinning.
        var finished: Set<String> = []
        while !Task.isCancelled {
            let jobs = store.all()
            guard !jobs.isEmpty else {
                running = nil
                return
            }
            var wait = false
            for job in jobs {
                if finished.contains(job.captureID) {
                    wait = true
                    continue
                }
                if await process(job) == .paused {
                    wait = true
                    break
                }
                finished.insert(job.captureID)
            }
            if wait {
                try? await Task.sleep(for: Self.pausedRetryDelay)
                finished.removeAll()
            }
        }
        running = nil
    }

    private enum Outcome { case done, paused }

    private func process(_ queued: MeetingTranscriptLLMJob) async -> Outcome {
        guard let refiner else { return .paused }
        let prompt = TranscriptLLMPromptPreference.meeting.prompt().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            // The pass is off: leave the transcript as recognized.
            store.remove(queued.captureID)
            return .done
        }
        guard let url = resolve(queued),
              let markdown = try? String(contentsOf: url, encoding: .utf8) else {
            log("MEETING LLM | a queued transcript is gone; dropping its job")
            store.remove(queued.captureID)
            return .done
        }
        if MeetingTranscriptLLMDocument.isProcessed(markdown) {
            store.remove(queued.captureID)
            return .done
        }
        var job = queued
        job.transcriptPath = url.path
        let utterances = MeetingTranscriptLLMDocument.utterances(in: markdown)
        let started = Date()
        var sinceCheckpoint = 0
        var refinedCount = 0
        for utterance in utterances where job.results[String(utterance.index)] == nil {
            if Task.isCancelled {
                try? store.save(job)
                return .paused
            }
            let key = String(utterance.index)
            let words = utterance.text.split(whereSeparator: \.isWhitespace).count
            var result = utterance.text
            if words >= Self.minimumWords {
                switch await refiner.refineMeetingUtterance(utterance.text) {
                case let .refined(text):
                    result = text
                    refinedCount += 1
                case .keep:
                    break
                case .unavailable:
                    try? store.save(job)
                    return .paused
                }
            }
            job.results[key] = result
            job.originals[key] = utterance.text
            sinceCheckpoint += 1
            if sinceCheckpoint >= Self.checkpointEvery {
                try? store.save(job)
                sinceCheckpoint = 0
            }
        }
        try? store.save(job)
        let modelID = await refiner.meetingRefinerModelID
        return await commit(job, modelID: modelID, refinedCount: refinedCount, started: started)
    }

    private func commit(
        _ job: MeetingTranscriptLLMJob,
        modelID: String,
        refinedCount: Int,
        started: Date
    ) async -> Outcome {
        // Read again right before writing: anything that changed the file
        // while the model ran (a speaker rename, a title edit) is kept.
        guard let url = resolve(job), let current = try? String(contentsOf: url, encoding: .utf8) else {
            store.remove(job.captureID)
            return .done
        }
        let replacements = Dictionary(uniqueKeysWithValues: job.results.compactMap { key, value -> (Int, String)? in
            guard let index = Int(key), job.originals[key] != value else { return nil }
            return (index, value)
        })
        let originals = Dictionary(uniqueKeysWithValues: job.originals.compactMap { key, value -> (Int, String)? in
            Int(key).map { ($0, value) }
        })
        let rewrite = MeetingTranscriptLLMDocument.applying(replacements, originals: originals, to: current, marker: modelID)
        do {
            try store.backupOriginal(current, captureID: job.captureID)
            try TranscriptFileRewrite.write(rewrite.markdown, to: url)
        } catch {
            // Disk full or a blocked folder: keep the job and its results,
            // touch nothing, try again later.
            log("MEETING LLM | couldn't save the corrected transcript yet: \(error.localizedDescription)")
            return .paused
        }
        store.remove(job.captureID)
        let seconds = Int(Date().timeIntervalSince(started))
        log("MEETING LLM | corrected \(rewrite.applied) of \(job.results.count) utterances (\(refinedCount) refined this run, \(seconds)s)")
        onTranscriptChanged(url)
        return .done
    }

    /// The transcript's current file. A rename (restyle, title edit) moves it,
    /// so look it up by `capture_id` in the same folder when the saved path is
    /// gone.
    private func resolve(_ job: MeetingTranscriptLLMJob) -> URL? {
        let saved = URL(fileURLWithPath: job.transcriptPath)
        if FileManager.default.fileExists(atPath: saved.path) { return saved }
        let folder = saved.deletingLastPathComponent()
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        for url in candidates where url.pathExtension == "md" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            // Frontmatter only; summary fields can make it long.
            let head = (try? handle.read(upToCount: 65_536)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            try? handle.close()
            if MeetingTranscriptLLMDocument.captureID(in: head) == job.captureID { return url }
        }
        return nil
    }
}
