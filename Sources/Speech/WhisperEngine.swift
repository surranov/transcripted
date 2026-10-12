// WhisperEngine.swift
// WhisperKit-backed local STT engine for advanced Transcripted model choices.

import FluidAudio
import Foundation
import TranscriptedCore
@preconcurrency import WhisperKit

@MainActor
final class WhisperEngine: ObservableObject {
    @Published private(set) var modelDownloadState: ParakeetModelState = .notLoaded

    private let modelRepo = "argmaxinc/whisperkit-coreml"
    private var whisperKit: WhisperKit?
    private var loadedModel: TranscriptionModelChoice?
    private var initializingModel: TranscriptionModelChoice?
    private var initializationTask: Task<Void, Never>?
    private var initializationGeneration = SupersessionEpoch()
    /// Fork: Breeze runs through whisper.cpp; see the Breeze section below.
    private let breeze = WhisperCppTranscriber()
    private var liveDictation: BreezeLiveDictation?
    private var liveDictationModel: TranscriptionModelChoice?
    private var detachLiveDictationSink: (() -> Void)?

    /// Ties the cached-model manifest to this app build, so the first Whisper
    /// load after an update re-checks Hugging Face once, like every load did.
    private static let cacheRevision: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)-\(build)"
    }()

    func isModelLoaded(for model: TranscriptionModelChoice) -> Bool {
        let engineLoaded = model.usesWhisperCpp ? breeze.isLoaded : whisperKit != nil
        return loadedModel == model && engineLoaded && modelDownloadState.isReady
    }

    func initialize(model: TranscriptionModelChoice) async {
        guard model.isWhisper else { return }

        if isModelLoaded(for: model) {
            return
        }

        if let initializationTask, initializingModel == model {
            await initializationTask.value
            return
        }

        initializationTask?.cancel()
        let generation = initializationGeneration.begin()
        initializingModel = model

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.load(model: model, generation: generation)
        }
        initializationTask = task
        await task.value

        if initializationGeneration.finishIfCurrent(generation) {
            initializationTask = nil
            initializingModel = nil
        }
    }

    func transcribeSamples(
        _ samples: [Float],
        source: AudioSource,
        model: TranscriptionModelChoice,
        languageCode: String? = nil
    ) async throws -> String {
        try Task.checkCancellation()
        guard model.isWhisper else {
            throw NSError(domain: "WhisperEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not a Whisper model."
            ])
        }

        if !isModelLoaded(for: model) {
            await initialize(model: model)
        }

        try Task.checkCancellation()
        if model.usesWhisperCpp {
            return try await transcribeWithBreeze(samples, source: source, model: model, languageCode: languageCode)
        }
        guard let whisperKit, isModelLoaded(for: model) else {
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "asr_manager_unavailable",
                message: "WhisperKit model is not loaded",
                context: ["model": model.rawValue]
            )
            throw NSError(domain: "WhisperEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not loaded."
            ])
        }

        guard !samples.isEmpty else { return "" }

        let sourceDescription = source == .microphone ? "microphone" : "system"
        guard TranscriptedConstants.hasMinimumParakeetAudioSamples(samples.count) else {
            let duration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
            EventReporter.shared.capture(
                level: .warning,
                engine: model.engineName,
                event: "segment_too_short",
                message: "Skipped short audio segment before Whisper transcription",
                context: [
                    "audio_duration_s": String(format: "%.2f", duration),
                    "minimum_duration_s": String(format: "%.2f", TranscriptedConstants.parakeetMinimumAudioDuration),
                    "samples": "\(samples.count)",
                    "source": sourceDescription,
                    "model": model.rawValue,
                ]
            )
            return ""
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        do {
            let results = try await whisperKit.transcribe(
                audioArray: samples,
                decodeOptions: Self.decodeOptions(languageCode: languageCode, concurrentWorkerCount: 1)
            )
            try Task.checkCancellation()
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let transcript = SegmentedEngineTranscript(segmentTexts: results.map(\.text))
            let trimmed = transcript.uncorrected
            let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0

            AppLogger.transcription.info("WHISPER | \(model.title) transcribed \(sourceDescription) in \(String(format: "%.2f", elapsed))s, chars=\(trimmed.count)")
            EventReporter.shared.capture(
                level: .info,
                engine: model.engineName,
                event: source == .microphone ? "dictation_transcribed" : "meeting_segment_transcribed",
                message: "Whisper segment transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "model": model.rawValue,
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.2f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(trimmed.count)",
                    "source": sourceDescription,
                ]
            )

            // The user's custom dictionary, mirroring ParakeetEngine. Without it,
            // proper-noun corrections silently fail on the Whisper path.
            return transcript.text
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "transcription_failed",
                message: error.localizedDescription,
                context: [
                    "model": model.rawValue,
                    "samples": "\(samples.count)",
                    "source": sourceDescription,
                    "elapsed": String(format: "%.2f", elapsed),
                ]
            )
            throw error
        }
    }

    /// Segments WhisperKit decodes side by side in a meeting batch. Its own
    /// CLI default; each worker holds one decoder's state while it runs.
    static let meetingBatchWorkerCount = 4

    /// Transcribes meeting segments side by side through WhisperKit's batch
    /// API and returns one text per segment, in order. Every segment gets the
    /// same decode options as `transcribeSamples`, and WhisperKit decodes each
    /// one on its own, so a segment's text is the same as a one-by-one call;
    /// only the wall time changes. Throws if any segment fails, and the
    /// pipeline then transcribes the batch one by one.
    func transcribeMeetingSegments(
        _ segments: [[Float]],
        source: AudioSource,
        model: TranscriptionModelChoice,
        languageCode: String?
    ) async throws -> [String] {
        try Task.checkCancellation()
        guard model.isWhisper else {
            throw NSError(domain: "WhisperEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not a Whisper model."
            ])
        }
        if model.usesWhisperCpp {
            // One context decodes one segment at a time.
            var texts: [String] = []
            for segment in segments {
                texts.append(try await transcribeSamples(segment, source: source, model: model, languageCode: languageCode))
            }
            return texts
        }
        if !isModelLoaded(for: model) {
            await initialize(model: model)
        }
        try Task.checkCancellation()
        guard let whisperKit, isModelLoaded(for: model) else {
            throw NSError(domain: "WhisperEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not loaded."
            ])
        }

        // Same short-segment rule as `transcribeSamples`: those come back
        // empty without a model call.
        let eligible = segments.indices.filter {
            TranscriptedConstants.hasMinimumParakeetAudioSamples(segments[$0].count)
        }
        var texts = Array(repeating: "", count: segments.count)
        guard !eligible.isEmpty else { return texts }

        let startTime = CFAbsoluteTimeGetCurrent()
        let results = await whisperKit.transcribeWithResults(
            audioArrays: eligible.map { segments[$0] },
            decodeOptions: Self.decodeOptions(
                languageCode: languageCode,
                concurrentWorkerCount: Self.meetingBatchWorkerCount
            )
        )
        try Task.checkCancellation()
        guard results.count == eligible.count else {
            throw NSError(domain: "WhisperEngine", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Whisper returned \(results.count) results for \(eligible.count) segments."
            ])
        }
        for (index, result) in zip(eligible, results) {
            switch result {
            case .success(let segmentResults):
                texts[index] = SegmentedEngineTranscript(segmentTexts: segmentResults.map(\.text)).text
            case .failure(let error):
                if error is CancellationError { throw CancellationError() }
                throw error
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let audioDuration = eligible.reduce(0.0) {
            $0 + Double(segments[$1].count) / TranscriptedConstants.parakeetSampleRate
        }
        AppLogger.transcription.info("WHISPER | \(model.title) transcribed \(eligible.count) meeting segments side by side in \(String(format: "%.2f", elapsed))s")
        EventReporter.shared.capture(
            level: .info,
            engine: model.engineName,
            event: "meeting_segment_transcribed",
            message: "Whisper batch transcribed in \(String(format: "%.2f", elapsed))s",
            context: [
                "model": model.rawValue,
                "elapsed_s": String(format: "%.3f", elapsed),
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "rtf": String(format: "%.3f", audioDuration > 0 ? elapsed / audioDuration : 0),
                "segments": "\(eligible.count)",
                "source": source == .microphone ? "microphone" : "system",
            ]
        )
        return texts
    }

    /// Decode options every transcription uses. `concurrentWorkerCount` only
    /// sets how many audio arrays a batch call runs at once; with no chunking
    /// strategy it doesn't change how one array is decoded.
    private static func decodeOptions(languageCode: String?, concurrentWorkerCount: Int) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: languageCode,
            temperature: 0,
            detectLanguage: languageCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            concurrentWorkerCount: concurrentWorkerCount
        )
    }

    /// Detection is local, bounded, and job-scoped. Never store its result on
    /// this shared engine: dictation and the next meeting must stay independent.
    func resolveLanguage(
        representativeSamples: [[Float]],
        selection: TranscriptionLanguageSelection,
        model: TranscriptionModelChoice
    ) async throws -> TranscriptionLanguageContext {
        try Task.checkCancellation()
        let supportedCodes = Set(Constants.languages.values)
        if case let .explicit(code) = selection {
            guard supportedCodes.contains(code) else {
                throw NSError(domain: "WhisperEngine", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "That transcription language is not supported by Whisper. Choose Auto or another language."
                ])
            }
            return TranscriptionLanguageContext(selection: selection, languageCode: code, resolution: .explicit)
        }
        // Fork: no detection pass for Breeze; it uses the person's language
        // (`BreezeDictationLanguage`) when no code is given.
        if model.usesWhisperCpp {
            return TranscriptionLanguageContext(selection: selection, languageCode: nil, resolution: .automaticUncertain)
        }

        if !isModelLoaded(for: model) { await initialize(model: model) }
        try Task.checkCancellation()
        guard let whisperKit, isModelLoaded(for: model) else {
            throw NSError(domain: "WhisperEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not loaded."
            ])
        }

        var observations: [String?] = []
        for samples in representativeSamples.prefix(3) {
            try Task.checkCancellation()
            // Core supplies speech-selected windows. Keep a second bound at
            // the engine seam for direct callers and reject invalid PCM.
            let bounded = Array(samples.prefix(160_000))
            guard bounded.count >= 32_000, bounded.allSatisfy({ $0.isFinite }) else {
                observations.append(nil)
                continue
            }
            do {
                // `detectLangauge` is the spelling in pinned WhisperKit 0.18.
                // langProbs contains log probabilities, usually only the winner.
                let detected = try await whisperKit.detectLangauge(audioArray: bounded)
                try Task.checkCancellation()
                observations.append(MeetingLanguageDetectionPolicy.confidentLanguage(
                    code: detected.language,
                    logProbability: detected.langProbs[detected.language],
                    supportedCodes: supportedCodes
                ))
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                // Detection is advisory. An unavailable/ambiguous result must
                // not discard a recording; retain the existing per-window Auto.
                observations.append(nil)
            }
        }
        switch MeetingLanguageDetectionPolicy.resolve(observations) {
        case .multilingual:
            return TranscriptionLanguageContext(selection: selection, languageCode: nil, resolution: .multilingual)
        case let .detected(code):
            return TranscriptionLanguageContext(selection: selection, languageCode: code, resolution: .detected)
        case .uncertain:
            return TranscriptionLanguageContext(selection: selection, languageCode: nil, resolution: .automaticUncertain)
        }
    }

    /// `beforeQuit` waits for whisper.cpp to free Breeze (see
    /// `WhisperCppTranscriber.unload`); a model switch doesn't.
    func cleanup(beforeQuit: Bool = false) {
        initializationGeneration.invalidate()
        initializationTask?.cancel()
        initializationTask = nil
        initializingModel = nil
        let pipe = whisperKit
        whisperKit = nil
        loadedModel = nil
        modelDownloadState = .notLoaded
        endLiveDictation()
        breeze.unload(waitUntilFreed: beforeQuit)
        Task {
            await pipe?.unloadModels()
        }
    }

    private func load(model: TranscriptionModelChoice, generation: SupersessionEpoch.Token) async {
        if model.usesWhisperCpp {
            await loadBreeze(model: model, generation: generation)
            return
        }
        guard let variant = model.whisperKitModelName else { return }
        guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }

        if loadedModel != model {
            let existing = whisperKit
            whisperKit = nil
            loadedModel = nil
            endLiveDictation()
            breeze.unload()
            await existing?.unloadModels()
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
        }

        modelDownloadState = .downloading(progress: 0)
        AppLogger.transcription.info("WHISPER | preparing \(model.title) (\(variant))...")

        do {
            let downloadBase = FileManager.default.transcriptedWhisperModelsDir
            let repo = modelRepo
            // Fast path: a Transcripted-written manifest that still matches the
            // disk lets us skip the Hugging Face listing + HEADs (and works
            // offline). Any mismatch, or a failed cached load, falls back to
            // the original download-then-load path once.
            let outcome = try await WhisperCachedModelLoad.run(
                downloadBase: downloadBase,
                repo: repo,
                variant: variant,
                revision: Self.cacheRevision,
                isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.initializationGeneration.isCurrent(generation)
                },
                willLoad: { [weak self] folder, cached in
                    guard let self else { return }
                    self.modelDownloadState = .loading
                    if cached {
                        AppLogger.transcription.info("WHISPER | using cached \(model.title) from \(folder.path)")
                    } else {
                        AppLogger.transcription.info("WHISPER | loading \(model.title) from \(folder.path)")
                    }
                },
                download: { [weak self] in
                    // Only after a failed cached load; the normal path is
                    // already .downloading(progress: 0) from above.
                    if let self, self.modelDownloadState == .loading {
                        self.modelDownloadState = .downloading(progress: 0)
                    }
                    return try await WhisperKit.download(
                        variant: variant,
                        downloadBase: downloadBase,
                        useBackgroundSession: false,
                        from: repo
                    ) { [weak self] progress in
                        Task { @MainActor in
                            guard
                                let self,
                                self.initializationGeneration.isCurrent(generation),
                                self.initializingModel == model
                            else { return }
                            self.modelDownloadState = .downloading(progress: progress.fractionCompleted)
                        }
                    }
                },
                load: { folder in
                    let config = WhisperKitConfig(
                        model: variant,
                        downloadBase: downloadBase,
                        modelRepo: repo,
                        modelFolder: folder.path,
                        verbose: false,
                        logLevel: .error,
                        prewarm: false,
                        load: true,
                        download: false,
                        useBackgroundDownloadSession: false
                    )
                    return try await WhisperKit(config)
                }
            )

            guard let outcome else { return }
            let pipe = outcome.pipe
            let modelFolder = outcome.modelFolder
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else {
                await pipe.unloadModels()
                return
            }

            whisperKit = pipe
            loadedModel = model
            modelDownloadState = .ready
            EventReporter.shared.capture(
                level: .info,
                engine: model.engineName,
                event: "model_ready",
                message: "\(model.title) initialized successfully",
                context: [
                    "model": model.rawValue,
                    "variant": variant,
                    "repo": modelRepo,
                    "model_path": modelFolder.lastPathComponent,
                ]
            )
        } catch {
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
            let friendlyMessage = "Couldn't load \(model.title): \(error.localizedDescription)"
            AppLogger.transcription.error("WHISPER | \(friendlyMessage)")
            modelDownloadState = .failed(friendlyMessage)
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "model_init_failed",
                message: friendlyMessage,
                context: [
                    "model": model.rawValue,
                    "variant": variant,
                    "repo": modelRepo,
                ]
            )
        }
    }
    // MARK: - Breeze (fork)

    /// Loads the script-installed Breeze files into whisper.cpp. Never
    /// downloads: a missing install fails with a path-free message the model
    /// card can show.
    private func loadBreeze(model: TranscriptionModelChoice, generation: SupersessionEpoch.Token) async {
        guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
        if loadedModel != model {
            let existing = whisperKit
            whisperKit = nil
            loadedModel = nil
            await existing?.unloadModels()
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
        }
        guard WhisperCppTranscriber.isAvailableInThisBuild else {
            failBreezeLoad(model: model, message: BreezeModelInstall.notBuiltMessage, event: "model_not_built")
            return
        }
        guard BreezeModelInstall.isInstalled() else {
            failBreezeLoad(model: model, message: BreezeModelInstall.notInstalledMessage, event: "model_not_installed")
            return
        }
        modelDownloadState = .loading
        let startTime = CFAbsoluteTimeGetCurrent()
        AppLogger.transcription.info("WHISPER | loading \(model.title) through whisper.cpp")
        do {
            try await breeze.load(weightsURL: BreezeModelInstall.weightsURL())
            // Superseded: leave the context alone. Whatever superseded this
            // load frees it (cleanup) or replaces it (the next load), and an
            // unload here could free a newer load's context instead.
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
            loadedModel = model
            modelDownloadState = .ready
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            AppLogger.transcription.info("WHISPER | \(model.title) ready in \(String(format: "%.1f", elapsed))s")
            EventReporter.shared.capture(
                level: .info,
                engine: model.engineName,
                event: "model_ready",
                message: "\(model.title) initialized successfully",
                context: ["model": model.rawValue, "runtime": "whisper_cpp", "elapsed_s": String(format: "%.1f", elapsed)]
            )
        } catch {
            guard initializationGeneration.isCurrent(generation), !Task.isCancelled else { return }
            failBreezeLoad(model: model, message: BreezeModelInstall.loadFailedMessage, event: "model_init_failed")
        }
    }

    private func failBreezeLoad(model: TranscriptionModelChoice, message: String, event: String) {
        AppLogger.transcription.error("WHISPER | \(message)")
        modelDownloadState = .failed(message)
        EventReporter.shared.capture(
            level: .error,
            engine: model.engineName,
            event: event,
            message: message,
            context: ["model": model.rawValue, "runtime": "whisper_cpp"]
        )
    }

    /// The language Breeze transcribes in when the caller gives none.
    private func breezeLanguage() -> String? {
        let meeting = TranscriptionLanguagePreferences.preferredLanguageCode()
        return BreezeDictationLanguage.code(
            userLanguageCodes: DictationUserLanguages.current(),
            explicitMeetingLanguage: meeting == TranscriptionLanguagePreferences.automaticValue ? nil : meeting
        )
    }

    private func transcribeWithBreeze(
        _ samples: [Float],
        source: AudioSource,
        model: TranscriptionModelChoice,
        languageCode: String?
    ) async throws -> String {
        guard isModelLoaded(for: model) else {
            throw NSError(domain: "WhisperEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "\(model.title) is not loaded."
            ])
        }
        guard TranscriptedConstants.hasMinimumParakeetAudioSamples(samples.count) else { return "" }
        let sourceDescription = source == .microphone ? "microphone" : "system"
        let prompt = BreezeDictationPrompt.make(dictionary: CustomDictionaryPreferences.entries(), precedingText: "")
        let startTime = CFAbsoluteTimeGetCurrent()
        let text = try await breeze.transcribe(samples, language: languageCode ?? breezeLanguage(), prompt: prompt)
        try Task.checkCancellation()
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
        let transcript = SegmentedEngineTranscript(segmentTexts: [text])
        AppLogger.transcription.info("WHISPER | \(model.title) transcribed \(sourceDescription) in \(String(format: "%.2f", elapsed))s, chars=\(transcript.uncorrected.count)")
        EventReporter.shared.capture(
            level: .info,
            engine: model.engineName,
            event: source == .microphone ? "dictation_transcribed" : "meeting_segment_transcribed",
            message: "Whisper segment transcribed in \(String(format: "%.2f", elapsed))s",
            context: [
                "model": model.rawValue,
                "elapsed_s": String(format: "%.3f", elapsed),
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "rtf": String(format: "%.3f", audioDuration > 0 ? elapsed / audioDuration : 0),
                "chars": "\(transcript.uncorrected.count)",
                "source": sourceDescription,
            ]
        )
        return transcript.text
    }

    /// Called as every take starts recording. For Breeze with the model
    /// loaded, transcribes the take in pieces while it records; any other
    /// model, or a Breeze still loading, records as before.
    /// A device-recovery restart inside the take (`continuingTake`) keeps the
    /// pieces so far: the sink stays attached, and audio lost in the gap is
    /// lost from the take's own samples too.
    func beginLiveDictation(
        model: TranscriptionModelChoice,
        continuingTake: Bool = false,
        attachSink: @escaping (DictationPreviewSampleSink?) -> Void
    ) {
        if continuingTake, liveDictation != nil, liveDictationModel == model { return }
        endLiveDictation()
        guard model.usesWhisperCpp, isModelLoaded(for: model) else { return }
        let dictionary = CustomDictionaryPreferences.entries()
        let live = BreezeLiveDictation(
            transcriber: breeze,
            language: breezeLanguage(),
            prompt: { precedingText in
                BreezeDictationPrompt.make(dictionary: dictionary, precedingText: precedingText)
            }
        )
        liveDictation = live
        liveDictationModel = model
        detachLiveDictationSink = { attachSink(nil) }
        attachSink(live.sink)
        live.start()
    }

    /// Stop, cancel or a failed start: drops the live pieces. Idempotent.
    func endLiveDictation() {
        detachLiveDictationSink?()
        detachLiveDictationSink = nil
        liveDictation?.cancel()
        liveDictation = nil
    }

    /// A dictation take at Stop. Breeze returns the pieces it transcribed
    /// while recording plus the last one; if anything about them is in doubt
    /// it transcribes the whole take, like the other Whisper models always do.
    func transcribeDictationTake(_ samples: [Float], model: TranscriptionModelChoice) async throws -> String {
        if model.usesWhisperCpp, let live = liveDictation {
            detachLiveDictationSink?()
            detachLiveDictationSink = nil
            liveDictation = nil
            let startTime = CFAbsoluteTimeGetCurrent()
            if let pieces = await live.finish(fullSampleCount: samples.count) {
                try Task.checkCancellation()
                let summary = live.summary
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                AppLogger.transcription.info("WHISPER | \(model.title) live take: pieces=\(summary.pieces) reused_speculation=\(summary.reusedSpeculation) tail_s=\(String(format: "%.2f", elapsed))")
                return SegmentedEngineTranscript(segmentTexts: pieces).text
            }
            try Task.checkCancellation()
            AppLogger.transcription.info("WHISPER | \(model.title) live take fell back to the whole take")
        }
        return try await transcribeSamples(samples, source: .microphone, model: model)
    }
}
