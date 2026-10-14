import Foundation

/// Runs the transcript LLM for the app's lifetime: downloads and verifies the
/// models the two passes picked, keeps a `llama-server` helper up per model
/// (Writing's process host, `.chat` profile, a slot per pass it serves; see
/// `TranscriptLLMEngineLayout`), keeps the prompts cached in them, refines
/// dictation text before paste (`DictationTextRefiner`) and meeting
/// utterances after save (`MeetingUtteranceRefiner`, in `+Meeting.swift`).
///
/// Always on, no toggle: an empty prompt is the only off switch. Nothing here
/// can cost the user a dictation or a meeting: every path that isn't a clean,
/// accepted answer keeps the recognized text.
///
/// `TranscriptedAppState` owns one: `start(log:)` at launch,
/// `handleSystemWake()` on wake, `stop()` at quit.
@MainActor
final class TranscriptLLMController: DictationTextRefiner {
    /// One helper of the layout as it runs: its model's download and
    /// verification, the process host, and the tasks working on them.
    @MainActor
    final class EngineRuntime {
        let engine: TranscriptLLMEngineLayout.Engine
        let models: ModelManager
        let host: LlamaServerProcessHost
        var preparationTask: Task<Void, Never>?
        var warmTask: Task<Void, Never>?

        init(engine: TranscriptLLMEngineLayout.Engine) {
            self.engine = engine
            let models = ModelManager(
                descriptor: TranscriptLLMModel.descriptor(for: engine.model),
                rootDirectory: TranscriptLLMModel.modelRoot
            )
            self.models = models
            host = LlamaServerProcessHost(
                port: engine.port,
                profile: .chat(
                    contextTokens: TranscriptLLMModel.contextTokens,
                    slots: engine.passes.count,
                    diagnosticsLabel: TranscriptLLMModel.diagnosticsLabel
                ),
                modelFileProvider: { models.verifiedInstalledModelFile() }
            )
        }

        /// Stops the download and prompt warming. A resumable `.partial`
        /// stays on disk; the helper is stopped separately.
        func cancelWork() {
            preparationTask?.cancel()
            preparationTask = nil
            warmTask?.cancel()
            warmTask = nil
            models.cancel()
        }
    }

    private(set) var layout: TranscriptLLMEngineLayout?
    private(set) var engines: [EngineRuntime] = []
    /// Applies model choices one change at a time, after the launch reap:
    /// helpers leaving the layout are shut down before new ones take their
    /// port.
    private var reconfiguration: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
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
        let center = NotificationCenter.default
        observers = TranscriptLLMPass.allCases.map { pass in
            center.addObserver(forName: pass.prompt.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.warmPrompts() }
            }
        }
        observers.append(center.addObserver(
            forName: TranscriptLLMModelPreference.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyModelChoices() }
        })
        reconfiguration = Task { @MainActor [weak self] in
            // A helper a crashed run left behind holds ~3 GB until reaped.
            // lsof/ps shell-outs: never on the main thread.
            await Task.detached(priority: .utility) {
                for port in TranscriptLLMEngineLayout.ports {
                    LlamaServerProcessHost.reapOrphanedHelper(port: port)
                }
            }.value
            await self?.applyLayout()
        }
        log("TRANSCRIPT LLM | starting")
    }

    func handleSystemWake() {
        guard isStarted, !isStopped else { return }
        engines.forEach(ensureRunning)
    }

    /// Safe to call more than once. Bounded: each helper gets TERM, then KILL
    /// after a second, so a quit can't orphan it.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        reconfiguration?.cancel()
        reconfiguration = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        for runtime in engines {
            runtime.cancelWork()
            runtime.host.stop()
        }
    }

    /// One line per pass for Settings. Reads in-memory state only.
    func statusLine(for pass: TranscriptLLMPass) -> String {
        guard isStarted, !isStopped else { return "Off" }
        guard let runtime = runtime(for: pass) else { return "Starting…" }
        return statusLine(runtime)
    }

    private func statusLine(_ runtime: EngineRuntime) -> String {
        switch runtime.models.state {
        case .checking: return "Checking the model…"
        case .missing: return "Model not downloaded yet"
        case let .downloading(received, total):
            return "Downloading the model: \(Self.gigabytes(received)) of \(Self.gigabytes(total)) GB"
        case .verifying: return "Verifying the model…"
        case let .failed(failure): return "Model download failed (\(Self.describe(failure))), retrying"
        case .ready:
            switch runtime.host.snapshot {
            case .starting: return "Starting…"
            case .ready: return "Ready"
            case .retrying: return "Engine restarting…"
            case .failed: return "Engine stopped, retrying on the next request"
            }
        }
    }

    // MARK: - Models

    /// Deletes a model no pass runs anymore, with any partial download, once
    /// a model switch still shutting its helper down is done. Deletes nothing
    /// when a pass picked the model again meanwhile.
    func deleteUnusedModel(_ model: TranscriptLLMModelChoice) async -> TranscriptLLMModelDeletion {
        applyModelChoices()
        await reconfiguration?.value
        guard !TranscriptLLMModelPreference.modelsInUse().contains(model), layout?.runs(model) != true else {
            return .inUse
        }
        let manager = ModelManager(
            descriptor: TranscriptLLMModel.descriptor(for: model),
            rootDirectory: TranscriptLLMModel.modelRoot
        )
        await manager.deleteModelAndWait()
        guard manager.state == .missing else {
            log("TRANSCRIPT LLM | couldn't delete \(model.rawValue)")
            return .failed
        }
        // Only an empty folder goes; anything else in it stays.
        _ = rmdir(manager.modelDirectory.path)
        log("TRANSCRIPT LLM | deleted \(model.rawValue); no pass runs it")
        return .deleted
    }

    /// Queues a move onto the layout the saved model choices ask for.
    private func applyModelChoices() {
        guard isStarted, !isStopped else { return }
        let previous = reconfiguration
        reconfiguration = Task { @MainActor [weak self] in
            await previous?.value
            await self?.applyLayout()
        }
    }

    /// Moves the passes onto the layout the saved choices ask for. A helper
    /// whose model, port and passes stay the same keeps running with its
    /// cached prompts. Any other is shut down off the main thread (TERM, KILL
    /// after a second) before its replacement starts, so the port is free.
    /// A pass in flight on a retiring helper fails over like a dead helper:
    /// a dictation keeps its recognized text, a meeting utterance is retried.
    private func applyLayout() async {
        guard isStarted, !isStopped else { return }
        let next = TranscriptLLMEngineLayout()
        guard next != layout else { return }
        let retiring = engines.filter { !next.engines.contains($0.engine) }
        retiring.forEach { $0.cancelWork() }
        engines.removeAll { runtime in retiring.contains { $0 === runtime } }
        let hosts = retiring.map(\.host)
        if !hosts.isEmpty {
            await Task.detached(priority: .userInitiated) {
                hosts.forEach { $0.stop() }
            }.value
        }
        guard isStarted, !isStopped else { return }
        let kept = engines
        engines = next.engines.map { engine in
            kept.first { $0.engine == engine } ?? makeRuntime(engine)
        }
        layout = next
        for engine in next.engines {
            let passes = engine.passes.map(\.rawValue).joined(separator: " + ")
            log("TRANSCRIPT LLM | \(passes) on \(engine.model.rawValue), port \(engine.port)")
        }
        for runtime in engines where !kept.contains(where: { $0 === runtime }) {
            prepare(runtime)
        }
    }

    private func makeRuntime(_ engine: TranscriptLLMEngineLayout.Engine) -> EngineRuntime {
        let runtime = EngineRuntime(engine: engine)
        // A fresh helper has empty prompt caches: refill them.
        runtime.host.setReadinessObserver { [weak self, weak runtime] ready in
            guard ready else { return }
            Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime else { return }
                self.warmPrompts(runtime)
            }
        }
        return runtime
    }

    func runtime(for pass: TranscriptLLMPass) -> EngineRuntime? {
        engines.first { $0.engine.passes.contains(pass) }
    }

    private func isCurrent(_ runtime: EngineRuntime) -> Bool {
        isStarted && !isStopped && engines.contains { $0 === runtime }
    }

    // MARK: - Dictation

    func refine(_ text: String) async -> DictationTextRefinement {
        let prompt = Self.systemPrompt(.dictation)
        guard !prompt.isEmpty else { return .unchanged(.noPrompt) }
        guard isStarted, !isStopped, let runtime = runtime(for: .dictation) else { return .unchanged(.notReady) }
        let host = runtime.host
        let slot = runtime.engine.slot(of: .dictation)
        dictationsInFlight += 1
        defer { dictationsInFlight -= 1 }
        guard await waitUntilEngineReady(runtime) else {
            if Task.isCancelled { return .unchanged(.cancelled) }
            ensureRunning(runtime)
            log("TRANSCRIPT LLM | not ready (\(statusLine(runtime))); keeping the recognized text")
            return .unchanged(.notReady)
        }
        let started = CFAbsoluteTimeGetCurrent()
        let chunks = DictationRefinementChunking.chunks(of: text)
        if chunks.count > 1 {
            return await refineInPieces(text, chunks: chunks, prompt: prompt, host: host, slot: slot, started: started)
        }
        let outcome = await Self.complete(
            host: host,
            slot: slot,
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
        slot: Int,
        started: CFAbsoluteTime
    ) async -> DictationTextRefinement {
        var pieces: [String] = []
        var kept = 0
        for chunk in chunks {
            let outcome = await Self.complete(
                host: host,
                slot: slot,
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

    private func prepare(_ runtime: EngineRuntime) {
        runtime.preparationTask?.cancel()
        runtime.preparationTask = Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return }
            await self.prepareModelAndStartEngine(runtime)
        }
    }

    private func prepareModelAndStartEngine(_ runtime: EngineRuntime) async {
        var attempt = 0
        let model = runtime.engine.model.rawValue
        while !Task.isCancelled, isCurrent(runtime) {
            runtime.models.prepare()
            await runtime.models.waitUntilSettled()
            guard !Task.isCancelled, isCurrent(runtime) else { return }
            if runtime.models.state.isReady {
                log("TRANSCRIPT LLM | \(model) ready; starting its engine")
                runtime.host.start()
                return
            }
            let delays = TranscriptLLMModel.downloadRetryDelays
            let delay = delays[min(attempt, delays.count - 1)]
            attempt += 1
            log("TRANSCRIPT LLM | \(model) not ready (\(statusLine(runtime))); retrying in \(delay)")
            try? await Task.sleep(for: delay)
        }
    }

    /// Restarts whatever stopped. A model that isn't ready gets a fresh
    /// preparation pass right away instead of waiting out the retry delay; a
    /// download already running is joined, not restarted (the manager owns
    /// it). A helper that gave up on missing assets gets the model re-verified
    /// first. A helper that is up, or coming up, is left alone.
    func ensureRunning(_ runtime: EngineRuntime) {
        guard isCurrent(runtime) else { return }
        let assetsMissing = runtime.host.snapshot == .failed(.assetsMissing)
        guard runtime.models.state.isReady, !assetsMissing else {
            if assetsMissing { runtime.models.refresh() }
            prepare(runtime)
            return
        }
        runtime.host.start()
    }

    /// Waits only while a verified model's helper is still coming up (it
    /// loads in a few seconds after launch or a model switch). Anything else
    /// answers now.
    func waitUntilEngineReady(_ runtime: EngineRuntime) async -> Bool {
        while !Task.isCancelled {
            if await runtime.host.isReadyForCompletion() { return true }
            guard isCurrent(runtime), runtime.models.state.isReady, runtime.host.snapshot == .starting else {
                return false
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func warmPrompts() {
        engines.forEach(warmPrompts)
    }

    /// Sends each non-empty prompt the helper serves once, on its pass's
    /// slot, so the helper caches it; the next request then reads only its
    /// own text.
    private func warmPrompts(_ runtime: EngineRuntime) {
        runtime.warmTask?.cancel()
        guard isCurrent(runtime) else { return }
        let host = runtime.host
        let prompts = runtime.engine.passes.enumerated().map { (slot: $0.offset, prompt: Self.systemPrompt($0.element)) }
        runtime.warmTask = Task {
            guard await host.isReadyForCompletion() else { return }
            for (slot, prompt) in prompts where !prompt.isEmpty {
                guard !Task.isCancelled else { return }
                _ = await Self.complete(host: host, slot: slot, systemPrompt: prompt, transcript: "", maxTokens: 1)
            }
        }
    }

    static func systemPrompt(_ pass: TranscriptLLMPass) -> String {
        pass.prompt.prompt().trimmingCharacters(in: .whitespacesAndNewlines)
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
        slot: Int,
        systemPrompt: String,
        transcript: String,
        maxTokens: Int
    ) async -> Outcome {
        guard let body = try? TranscriptLLMChat.requestBody(
            systemPrompt: systemPrompt, transcript: transcript, maxTokens: maxTokens, slot: slot
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
