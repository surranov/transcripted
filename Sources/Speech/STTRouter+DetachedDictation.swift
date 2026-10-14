// STTRouter+DetachedDictation.swift
// Fork: the dictation queue. A stopped take whose audio is safe in its
// recovery WAV takes everything that is its own out of the engine: the
// samples (the engine's timeline is cleared), its recording model's
// foreground use, Breeze's live pieces and the pinned mic's speed-path mark.
// The next take can then record at once into a fresh timeline, while this
// one waits its turn and is transcribed from its own copy. Takes are
// transcribed one at a time, in the order they stopped; Parakeet's decoder
// and whisper.cpp each run one call at a time anyway, so a queue costs
// nothing and keeps a take's retry together with its first pass.

import Foundation

/// A stopped take that owns its audio and model. Made by
/// `detachStoppedDictation`; `transcribeDetachedDictation` consumes it once.
struct DetachedDictationTake {
    let recording: RecordedSpeechSamples
    /// The take's recording model. Its foreground use is the take's until
    /// the take is transcribed, so a model switch can't unload it mid-take.
    let model: TranscriptionModelChoice
    /// Breeze's pieces transcribed while this take recorded.
    let live: BreezeLiveDictation?
    let pinnedSpeedPathTake: PinnedDictationSpeedPathTake?
    let micSentOnlyDigitalSilence: Bool
}

/// What a detached take's transcription found. The engine-wide
/// `lastEmptyTranscriptionReason` and `heldBackDictationText` belong to the
/// newest take, so a detached one carries its own.
struct DetachedDictationTranscript: Equatable {
    var text: String?
    var emptyReason: DictationEmptyTranscriptionReason?
    /// Text held back as `.otherLanguage`, for Paste Anyway. Memory only.
    var heldBackText: String?
}

extension STTRouter {
    /// Takes the stopped take out of the engine. Nil (and nothing changes)
    /// when there is no recording lease, or when the snapshot's claim no
    /// longer names the engine's recording: the take then goes the old way,
    /// holding the engine until it is transcribed.
    func detachStoppedDictation(_ recording: RecordedSpeechSamples) -> DetachedDictationTake? {
        guard let lease = recordingModelOwnership.activeLease,
              parakeetEngine.detachStoppedDictationRecording(recording) else { return nil }
        // Released without ending its foreground use: that is the take's now,
        // ended once it is transcribed.
        _ = recordingModelOwnership.release(ifMatching: lease)
        let pinned = parakeetEngine.pendingPinnedSpeedPathTake
        parakeetEngine.pendingPinnedSpeedPathTake = nil
        return DetachedDictationTake(
            recording: recording,
            model: lease.model,
            live: lease.model.usesWhisperCpp ? whisperEngine.detachLiveDictation() : nil,
            pinnedSpeedPathTake: pinned,
            micSentOnlyDigitalSilence: parakeetEngine.lastRecordingWasDigitalSilence
        )
    }

    /// Transcribes a detached take after every take detached before it.
    /// Cancelling the caller cancels this take only; the takes behind it
    /// still run in order. `isTranscribing` stays true while any is queued.
    func transcribeDetachedDictation(_ take: DetachedDictationTake) async -> DetachedDictationTranscript {
        detachedDictationTranscriptions += 1
        defer { detachedDictationTranscriptions = max(0, detachedDictationTranscriptions - 1) }
        return await detachedDictationLine.run { [weak self] in
            guard let self else { return DetachedDictationTranscript() }
            return await self.runDetachedDictation(take)
        }
    }

    private func runDetachedDictation(_ take: DetachedDictationTake) async -> DetachedDictationTranscript {
        defer {
            // Idempotent: `finish` already cancelled pieces it used; pieces
            // never asked for (cancelled, model gone) stop working now.
            take.live?.cancel()
            endForegroundUse(of: take.model)
        }
        guard !Task.isCancelled else { return DetachedDictationTranscript() }
        var transcript = DetachedDictationTranscript()
        switch take.model {
        case .parakeetTDTv2, .parakeetTDTv3, .parakeetUltraExperimental:
            guard isModelLoaded(for: take.model) else {
                transcript.emptyReason = .modelFailure
                EventReporter.shared.capture(
                    level: .error,
                    engine: "parakeet",
                    event: "asr_manager_unavailable",
                    message: "Requested Parakeet model is not available for transcription",
                    context: ["model": take.model.rawValue]
                )
                break
            }
            let result = await parakeetEngine.transcribeDetachedDictation(take.recording)
            transcript.text = result.text
            transcript.emptyReason = result.text == nil ? result.emptyReason : nil
        case .whisperLargeV3Turbo, .whisperLargeV3, .breezeASR25, .appleSpeech:
            transcript = await transcribeDetachedWithExternalEngine(take)
        }
        if !Task.isCancelled, let text = transcript.text,
           let heldBack = holdBackTextInUnexpectedScript(text, model: take.model) {
            transcript = DetachedDictationTranscript(text: nil, emptyReason: .otherLanguage, heldBackText: heldBack)
        }
        if let pinned = take.pinnedSpeedPathTake {
            parakeetEngine.scorePinnedSpeedPathTake(
                pinned,
                text: transcript.text ?? transcript.heldBackText,
                emptyReason: transcript.emptyReason,
                micSentOnlyDigitalSilence: take.micSentOnlyDigitalSilence
            )
        }
        return transcript
    }

    /// Whisper, Breeze and Apple Speech on the take's own samples (and
    /// Breeze's own pieces); the same empty and failure reasons as the
    /// engine-held path in `transcribeUsingExternalEngine`.
    private func transcribeDetachedWithExternalEngine(_ take: DetachedDictationTake) async -> DetachedDictationTranscript {
        let model = take.model
        await initialize(model: model)
        guard !Task.isCancelled else { return DetachedDictationTranscript() }
        guard isModelLoaded(for: model) else {
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "dictation_model_unavailable",
                message: "\(model.title) was selected but is not loaded",
                context: ["model": model.rawValue]
            )
            return DetachedDictationTranscript(emptyReason: .modelFailure)
        }
        let samples = take.recording.samples16k
        do {
            let text: String
            if model.isAppleSpeech {
                // Dictation has no language setting; Apple Speech uses the Mac's language.
                text = try await appleSpeechEngine.transcribeSamples(samples, source: .microphone, languageCode: nil)
            } else {
                text = try await whisperEngine.transcribeDictationTake(samples, model: model, live: take.live)
            }
            try Task.checkCancellation()
            if let emptyReason = DictationEmptyInferencePolicy.externalEngineEmptyReason(text: text, samples16k: samples) {
                return DetachedDictationTranscript(emptyReason: emptyReason)
            }
            return DetachedDictationTranscript(text: text)
        } catch {
            guard let failureReason = DictationEmptyInferencePolicy.externalEngineFailureReason(
                for: error,
                taskCancelled: Task.isCancelled
            ) else { return DetachedDictationTranscript() }
            EventReporter.shared.capture(
                level: .error,
                engine: model.engineName,
                event: "dictation_transcription_failed",
                message: error.localizedDescription,
                context: ["model": model.rawValue]
            )
            return DetachedDictationTranscript(emptyReason: failureReason)
        }
    }

    /// The text, when a multilingual model probably guessed a language this
    /// person doesn't use (Russian for an English speaker): don't paste it
    /// unasked; the message offers Paste Anyway in case the text is right.
    /// The policy reads the person's languages (a Carbon keyboard lookup)
    /// only when the text is nearly all one non-Latin script.
    func holdBackTextInUnexpectedScript(_ text: String, model: TranscriptionModelChoice) -> String? {
        guard let script = DictationLanguageScriptPolicy.unexpectedScript(
            in: text,
            userLanguageCodes: { DictationUserLanguages.current() }
        ) else { return nil }
        EventReporter.shared.capture(
            level: .warning,
            engine: "dictation",
            event: "dictation_output_language_mismatch",
            message: "Dictation text was in a writing system none of the Mac's languages use",
            context: ["model": model.rawValue, "script": script.rawValue]
        )
        return text
    }
}
