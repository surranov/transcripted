import Foundation

/// Runs the transcript LLM for the app's lifetime: downloads and verifies its
/// model, keeps its own `llama-server` helper up (Writing's process host,
/// `.chat` profile, one slot for dictation and one for meetings), keeps both
/// prompts cached in it, refines dictation text before paste
/// (`DictationTextRefiner`) and meeting utterances after save
/// (`MeetingUtteranceRefiner`, in `+Meeting.swift`).
///
/// Always on, no toggle: an empty prompt is the only off switch. Nothing here
/// can cost the user a dictation or a meeting: every path that isn't a clean,
/// accepted answer keeps the recognized text.
///
/// `TranscriptedAppState` owns one: `start(log:)` at launch,
/// `handleSystemWake()` on wake, `stop()` at quit.
@MainActor
final class TranscriptLLMController: DictationTextRefiner {
    private(set) var models: ModelManager?
    private(set) var host: LlamaServerProcessHost?
    private var preparationTask: Task<Void, Never>?
    private var warmTask: Task<Void, Never>?
    private var promptObservers: [NSObjectProtocol] = []
    private(set) var isStarted = false
    private(set) var isStopped = false
    /// Dictation passes in flight. A meeting pass waits for zero before each
    /// utterance, so a dictation gets the GPU to itself.
    private(set) var dictationsInFlight = 0
    private(set) var log: (String) -> Void = { _ in }

    init() {}

    func start(log: @escaping (String) -> Void) {
        guard !isStarted, !isStopped else { return }
        isStarted = true
        self.log = log
        let models = ModelManager(
            descriptor: TranscriptLLMModel.descriptor,
            rootDirectory: TranscriptLLMModel.modelRoot
        )
        let host = LlamaServerProcessHost(
            port: TranscriptLLMModel.port,
            profile: .chat(
                contextTokens: TranscriptLLMModel.contextTokens,
                slots: TranscriptLLMModel.Slot.allCases.count,
                diagnosticsLabel: TranscriptLLMModel.diagnosticsLabel
            ),
            modelFileProvider: { models.verifiedInstalledModelFile() }
        )
        // A fresh helper has empty prompt caches: refill them.
        host.setReadinessObserver { [weak self] ready in
            guard ready else { return }
            Task { @MainActor [weak self] in self?.warmPrompts() }
        }
        self.models = models
        self.host = host
        promptObservers = [TranscriptLLMPromptPreference.dictation, .meeting].map { preference in
            NotificationCenter.default.addObserver(
                forName: preference.didChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.warmPrompts() }
            }
        }
        let port = TranscriptLLMModel.port
        preparationTask = Task { @MainActor [weak self] in
            // A helper a crashed run left behind holds ~3 GB until reaped.
            // lsof/ps shell-outs: never on the main thread.
            await Task.detached(priority: .utility) {
                LlamaServerProcessHost.reapOrphanedHelper(port: port)
            }.value
            await self?.prepareModelAndStartEngine()
        }
        log("TRANSCRIPT LLM | starting (\(TranscriptLLMModel.descriptor.identifier))")
    }

    func handleSystemWake() {
        guard isStarted, !isStopped else { return }
        ensureRunning()
    }

    /// Safe to call more than once. Bounded: the helper gets TERM, then KILL
    /// after a second, so a quit can't orphan it.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        preparationTask?.cancel()
        preparationTask = nil
        warmTask?.cancel()
        warmTask = nil
        promptObservers.forEach { NotificationCenter.default.removeObserver($0) }
        promptObservers = []
        host?.stop()
        models?.cancel()
    }

    /// One line for Settings. Reads in-memory state only.
    var statusLine: String {
        guard isStarted, !isStopped, let models, let host else { return "Off" }
        switch models.state {
        case .checking: return "Checking the model…"
        case .missing: return "Model not downloaded yet"
        case let .downloading(received, total):
            return "Downloading the model: \(Self.gigabytes(received)) of \(Self.gigabytes(total)) GB"
        case .verifying: return "Verifying the model…"
        case let .failed(failure): return "Model download failed (\(Self.describe(failure))), retrying"
        case .ready:
            switch host.snapshot {
            case .starting: return "Starting…"
            case .ready: return "Ready"
            case .retrying: return "Engine restarting…"
            case .failed: return "Engine stopped, retrying on the next dictation"
            }
        }
    }

    // MARK: - Dictation

    func refine(_ text: String) async -> DictationTextRefinement {
        let prompt = Self.systemPrompt(.dictation)
        guard !prompt.isEmpty else { return .unchanged(.noPrompt) }
        guard isStarted, !isStopped, let host else { return .unchanged(.notReady) }
        dictationsInFlight += 1
        defer { dictationsInFlight -= 1 }
        guard await waitUntilEngineReady(host) else {
            if Task.isCancelled { return .unchanged(.cancelled) }
            ensureRunning()
            log("TRANSCRIPT LLM | not ready (\(statusLine)); keeping the recognized text")
            return .unchanged(.notReady)
        }
        let started = CFAbsoluteTimeGetCurrent()
        let chunks = DictationRefinementChunking.chunks(of: text)
        if chunks.count > 1 {
            return await refineInPieces(text, chunks: chunks, prompt: prompt, host: host, started: started)
        }
        let outcome = await Self.complete(
            host: host,
            slot: .dictation,
            systemPrompt: prompt,
            transcript: text,
            maxTokens: TranscriptLLMChat.maxTokens(transcript: text)
        )
        let elapsed = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - started)
        switch outcome {
        case let .answer(.text(answer)):
            guard let accepted = DictationTextRefinementPolicy.accepted(original: text, answer: answer) else {
                log("TRANSCRIPT LLM | answer rejected (\(text.count) → \(answer.count) chars, \(elapsed)s); keeping the recognized text")
                return .unchanged(.rejected)
            }
            log("TRANSCRIPT LLM | refined \(text.count) → \(accepted.count) chars in \(elapsed)s")
            return .refined(accepted)
        case .answer(.truncated):
            log("TRANSCRIPT LLM | answer cut off at the token limit (\(elapsed)s); keeping the recognized text")
            return .unchanged(.failed)
        case .answer(.malformed):
            log("TRANSCRIPT LLM | malformed answer (\(elapsed)s); keeping the recognized text")
            return .unchanged(.failed)
        case .cancelled:
            return .unchanged(.cancelled)
        case let .rejectedRequest(status):
            // 4xx: the request itself didn't fit (context overflow). The
            // helper is fine; don't restart it.
            log("TRANSCRIPT LLM | engine refused the request (HTTP \(status)); keeping the recognized text")
            return .unchanged(.failed)
        case .transportFailure:
            host.reportCompletionFailure()
            log("TRANSCRIPT LLM | engine unreachable (\(elapsed)s); restarting it, keeping the recognized text")
            return .unchanged(.failed)
        }
    }

    /// A long take, one piece at a time (`DictationRefinementChunking`). A
    /// piece whose answer doesn't pass keeps its recognized text; the rest
    /// are still refined. A dead helper or Esc keeps the whole take.
    private func refineInPieces(
        _ text: String,
        chunks: [DictationRefinementChunking.Chunk],
        prompt: String,
        host: LlamaServerProcessHost,
        started: CFAbsoluteTime
    ) async -> DictationTextRefinement {
        var pieces: [String] = []
        var kept = 0
        for chunk in chunks {
            let outcome = await Self.complete(
                host: host,
                slot: .dictation,
                systemPrompt: prompt,
                transcript: chunk.text,
                maxTokens: TranscriptLLMChat.maxTokens(transcript: chunk.text)
            )
            switch outcome {
            case let .answer(.text(answer)):
                if let accepted = DictationTextRefinementPolicy.accepted(original: chunk.text, answer: answer) {
                    pieces.append(accepted)
                } else {
                    pieces.append(chunk.text)
                    kept += 1
                }
            case .answer(.truncated), .answer(.malformed), .rejectedRequest:
                pieces.append(chunk.text)
                kept += 1
            case .cancelled:
                return .unchanged(.cancelled)
            case .transportFailure:
                host.reportCompletionFailure()
                log("TRANSCRIPT LLM | engine unreachable mid-take; restarting it, keeping the recognized text")
                return .unchanged(.failed)
            }
        }
        let elapsed = String(format: "%.2f", CFAbsoluteTimeGetCurrent() - started)
        guard kept < chunks.count else {
            log("TRANSCRIPT LLM | all \(chunks.count) pieces rejected (\(elapsed)s); keeping the recognized text")
            return .unchanged(.rejected)
        }
        let refined = DictationRefinementChunking.join(pieces, of: chunks)
        log("TRANSCRIPT LLM | refined \(text.count) → \(refined.count) chars in \(chunks.count) pieces (\(kept) kept as recognized) in \(elapsed)s")
        return .refined(refined)
    }

    // MARK: - Lifecycle

    private func prepareModelAndStartEngine() async {
        var attempt = 0
        while !Task.isCancelled, !isStopped, let models {
            models.prepare()
            await models.waitUntilSettled()
            guard !Task.isCancelled, !isStopped else { return }
            if models.state.isReady {
                log("TRANSCRIPT LLM | model ready; starting the engine")
                host?.start()
                return
            }
            let delays = TranscriptLLMModel.downloadRetryDelays
            let delay = delays[min(attempt, delays.count - 1)]
            attempt += 1
            log("TRANSCRIPT LLM | model not ready (\(statusLine)); retrying in \(delay)")
            try? await Task.sleep(for: delay)
        }
    }

    /// Restarts whatever stopped. A model that isn't ready gets a fresh
    /// preparation pass right away instead of waiting out the retry delay; a
    /// download already running is joined, not restarted (the manager owns
    /// it). A helper that gave up on missing assets gets the model re-verified
    /// first. A helper that is up, or coming up, is left alone.
    func ensureRunning() {
        guard isStarted, !isStopped, let models, let host else { return }
        let assetsMissing = host.snapshot == .failed(.assetsMissing)
        guard models.state.isReady, !assetsMissing else {
            if assetsMissing { models.refresh() }
            preparationTask?.cancel()
            preparationTask = Task { @MainActor [weak self] in
                await self?.prepareModelAndStartEngine()
            }
            return
        }
        host.start()
    }

    /// Waits only while a verified model's helper is still coming up (it
    /// loads in a second or two after launch). Anything else answers now.
    func waitUntilEngineReady(_ host: LlamaServerProcessHost) async -> Bool {
        while !Task.isCancelled {
            if await host.isReadyForCompletion() { return true }
            guard models?.state.isReady == true, host.snapshot == .starting else { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Sends each non-empty prompt once on its own slot so the helper caches
    /// it; the next request then reads only its own text.
    private func warmPrompts() {
        warmTask?.cancel()
        guard isStarted, !isStopped, let host else { return }
        let prompts = TranscriptLLMModel.Slot.allCases.map { ($0, Self.systemPrompt($0)) }
        warmTask = Task {
            guard await host.isReadyForCompletion() else { return }
            for (slot, prompt) in prompts where !prompt.isEmpty {
                guard !Task.isCancelled else { return }
                _ = await Self.complete(host: host, slot: slot, systemPrompt: prompt, transcript: "", maxTokens: 1)
            }
        }
    }

    static func systemPrompt(_ slot: TranscriptLLMModel.Slot) -> String {
        let preference: TranscriptLLMPromptPreference = slot == .dictation ? .dictation : .meeting
        return preference.prompt().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transport

    enum Outcome: Equatable, Sendable {
        case answer(TranscriptLLMChat.Answer)
        case rejectedRequest(Int)
        case transportFailure
        case cancelled
    }

    /// No practical timeout: the owner asked for none (2026-10-10), and Esc
    /// cancels the task, which cancels the request.
    nonisolated static let requestTimeout: TimeInterval = 3_600

    nonisolated static func complete(
        host: LlamaServerProcessHost,
        slot: TranscriptLLMModel.Slot,
        systemPrompt: String,
        transcript: String,
        maxTokens: Int
    ) async -> Outcome {
        guard let body = try? TranscriptLLMChat.requestBody(
            systemPrompt: systemPrompt, transcript: transcript, maxTokens: maxTokens, slot: slot.rawValue
        ) else { return .answer(.malformed) }
        var request = URLRequest(url: host.baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        host.accessKey.authorize(&request)
        do {
            let (data, response) = try await LocalhostURLSession.shared.data(for: request)
            if Task.isCancelled { return .cancelled }
            guard let http = response as? HTTPURLResponse else { return .transportFailure }
            switch http.statusCode {
            case 200: return .answer(TranscriptLLMChat.answer(from: data))
            case 400..<500: return .rejectedRequest(http.statusCode)
            default: return .transportFailure
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .transportFailure
        }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }

    private static func describe(_ failure: ModelFailure) -> String {
        switch failure {
        case .offline: "offline"
        case .insufficientDiskSpace: "not enough disk space"
        case .serverRejectedRequest: "server refused"
        case .checksumMismatch: "checksum mismatch"
        case .invalidModel: "invalid file"
        case .installationFailed: "couldn't install"
        }
    }
}
