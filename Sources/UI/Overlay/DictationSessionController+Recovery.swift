// DictationSessionController+Recovery.swift
// Saved-audio cleanup, Quit admission, Retry Saving, and recording interruptions.

import AppKit

extension DictationSessionController {
    /// Launch (fork): recover dictation audio an earlier run left behind
    /// instead of deleting it (upstream deleted the short ones). Takes a
    /// month old that still couldn't be recovered are deleted first; the rest
    /// are transcribed again once the voice model is free and saved to
    /// Dictations, dated when they were spoken (`DictationLeftoverRecovery`).
    /// File work runs off the main actor. This run's takes are newer than
    /// the launch time and are never touched.
    /// Skipped for a second copy run with the single-instance guard off: the
    /// first copy may be offering one of these files right now.
    func recoverLeftoverStoppedAudio() {
        guard let appState else { return }
        let logger = appState.logger
        guard !SingleInstanceGuard.isDisabledByEnvironment else {
            logger.log("DICTATION | leftover saved recordings kept: single-instance guard is off")
            return
        }
        let launchedAt = Date()
        Task { @MainActor [weak self] in
            let expired = await Task.detached(priority: .utility) {
                DictationStoppedAudioRecoveryStore.purgeLeftovers(
                    createdBefore: launchedAt.addingTimeInterval(-DictationLeftoverRecovery.maximumAge),
                    onlyShortTakes: false
                )
            }.value
            if expired > 0 {
                logger.log("DICTATION | removed \(expired) saved recording(s) a month old that couldn't be recovered")
            }
            let pending = await Task.detached(priority: .utility) {
                DictationLeftoverRecovery.earlierRuns(
                    DictationStoppedAudioRecoveryStore.pendingRecoveries(limit: Int.max),
                    launchedAt: launchedAt
                )
            }.value
            guard !pending.isEmpty, let self else { return }
            logger.log("DICTATION | recovering \(pending.count) saved recording(s) left from an earlier run")
            let summary = await self.runLeftoverRecovery(pending, appState: appState)
            logger.log(
                "DICTATION | leftover recovery: \(summary.recovered) saved, \(summary.noWords) without words, "
                    + "\(summary.failed) not recovered (kept for the next launch)"
            )
        }
    }

    private func runLeftoverRecovery(
        _ pending: [DictationStoppedAudioRecovery],
        appState: TranscriptedAppState
    ) async -> DictationLeftoverRecovery.Summary {
        let refiner: any DictationTextRefiner = appState.transcriptLLM
        let sttRouter = appState.sttRouter
        return await DictationLeftoverRecovery.run(DictationLeftoverRecovery.Steps(
            pending: { pending },
            loadSamples: { url in
                try await Task.detached(priority: .utility) {
                    try DictationRetranscription.loadSamples16k(from: url)
                }.value
            },
            transcribe: { samples in
                // Never compete with the user's own takes.
                guard await Self.waitUntilVoiceModelIsFree(sttRouter) else { throw CancellationError() }
                return try await sttRouter.transcribeSavedDictation(samples: samples)
            },
            // `transcribeSavedDictation` runs the dictation model.
            recognitionModel: { sttRouter.selectedModel.rawValue },
            clean: { raw in
                DictationRetranscription.cleanedText(raw, cleanupEnabled: DictationCleanupPreferences.isEnabled())
            },
            refine: { text in
                await DictationLeftoverRecovery.refineWhenReady(text) { await refiner.refine($0) }
            },
            save: { recovery, text, versions in
                let keepWindow = AudioStoragePreferences.dictationAudioKeepWindow()
                let result = await Task.detached(priority: .utility) {
                    DictationStoppedAudioRecoveryStore.saveTranscriptAndRetire(
                        recovery: recovery,
                        keepWindow: keepWindow
                    ) { audioRelativePath in
                        let saved = try DictationTranscriptWriter.save(
                            text: text,
                            sourceAppName: DictationLeftoverRecovery.sourceAppName,
                            sourceBundleID: nil,
                            delivery: .savedWithoutPaste,
                            createdAt: recovery.createdAt,
                            audioRelativePath: audioRelativePath
                        )
                        DictationTextVersionStore.record(versions, for: saved)
                        return saved
                    }
                }.value
                return result.saved != nil
            }
        ))
    }

    /// Waits (up to ten minutes) until no take records or transcribes. A
    /// recovery that can't get the model in that time waits for the next
    /// launch.
    private static func waitUntilVoiceModelIsFree(_ sttRouter: STTRouter) async -> Bool {
        for _ in 0..<600 {
            if Task.isCancelled { return false }
            if !sttRouter.isRecording, !sttRouter.isTranscribing, !sttRouter.isTranscribingSavedDictation {
                return true
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// The button on a message about a long take's saved recording. The
    /// messages used to point at Capture → Transcribe Audio File, a menu that
    /// only shows while Transcripted is frontmost. Transcribe It runs that
    /// same import on the saved file, and the meeting importer cleans the
    /// recording up once its transcript is saved.
    func savedDictationAudioAction(for url: URL) -> (title: String, action: () -> Void) {
        guard let onTranscribeSavedAudio else {
            return ("Show Audio", {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
        return (DictationSavedAudioActionCopy.transcribeTitle, { [weak self] in
            self?.overlayController?.hideWithConfirmAnimation()
            onTranscribeSavedAudio(url)
        })
    }

    // finishDictationForTermination (Quit) lives in
    // DictationSessionPipeline.swift, where tests run it on a fake controller.

    var currentStoppedAudioRecoveryWAVExists: Bool {
        guard let stoppedAudioRecovery,
              stoppedAudioRecovery.sessionID == currentDictationSessionID else { return false }
        return FileManager.default.fileExists(atPath: stoppedAudioRecovery.url.path)
    }

    func showFailedCheckpointRecoveryError() {
        guard let overlayController else { return }
        let message = "Audio is only in memory. Keep Transcripted open; check storage, then Retry Saving."
        guard !isDictating,
              appState?.sttRouter.hasRecoverableRecording == true,
              stoppedAudioCheckpointSignal != nil,
              !currentStoppedAudioRecoveryWAVExists else {
            overlayController.showError(
                "Audio couldn't be saved safely. Keep Transcripted open and contact support."
            )
            return
        }
        overlayController.showError(
            message,
            actionTitle: "Retry Saving",
            action: { [weak self] in self?.retrySavingRetainedDictationAudio() }
        )
    }

    private func retrySavingRetainedDictationAudio() {
        let sessionID = currentDictationSessionID
        guard let checkpointSignal = stoppedAudioCheckpointSignal else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await DictationRetainedAudioRetry.run(
                DictationRetainedAudioRetry.Steps(
                    waitForCheckpoint: {
                        await checkpointSignal.waitForCompletion(timeoutNanoseconds: 2_000_000_000)
                    },
                    onCheckpointTimeout: {
                        if self.currentDictationSessionID == sessionID && !self.isDictating {
                            self.showFailedCheckpointRecoveryError()
                        }
                    },
                    canRetry: {
                        guard let (appState, _) = self.readyState() else { return false }
                        return DictationTerminationAdmissionPolicy.canRetrySaving(
                            isDictating: self.isDictating,
                            checkpointSettled: true,
                            hasRecoverableRecording: appState.sttRouter.hasRecoverableRecording,
                            recoveryWAVExists: self.currentStoppedAudioRecoveryWAVExists,
                            isCurrentSession: self.currentDictationSessionID == sessionID,
                            hasPendingStart: self.startupTask != nil || self.recordingStartRetryTask != nil
                        )
                    },
                    // The previous stop has released its model lease and
                    // completed its checkpoint signal. Readmit this same
                    // retained recording only.
                    resetStopGate: { self.stopFinalizationGate.reset() },
                    readmit: {
                        // Not a microphone start: the App Nap label already
                        // says "stop finalization" (see `processActivityLabel`).
                        // The listening state is an admission input, not a new mic start.
                        self.isDictating = true
                        self.overlayController?.state = .listening
                        self.overlayController?.markRetainedRecordingForEscape()
                    },
                    stopWithoutPaste: { self.stopDictationAndPaste(trigger: .unknown, autoPaste: false) },
                    afterStop: {
                        guard let overlayController = self.overlayController,
                              self.isDictating,
                              self.stopFinalizationGate.admittedSessionID == sessionID else { return }
                        // The listening state above is only the stop-policy admission
                        // input. Present Saving immediately, including in mini mode.
                        overlayController.state = .drafting
                        overlayController.showLoadingState(
                            near: self.sessionSourceApp,
                            presentation: .init(
                                title: "Saving audio",
                                detail: "Retrying the recording already captured.",
                                progress: 0.2,
                                status: "Saving"
                            ),
                            anchorRect: self.sessionAnchorRect
                        )
                    }
                )
            )
        }
    }

    func handleDictationInterruption() {
        let plan = DictationInterruptionPlan.make(
            hasRecoverableRecording: appState?.sttRouter.hasRecoverableRecording ?? false
        )
        let interruptedSessionID = currentDictationSessionID
        let interruptedCheckpointSignal = stoppedAudioCheckpointSignal
        cancelActiveTasks(cancelRecording: plan.cancelRecording)
        // Fork: whatever reached the spool stays for the next launch, even if
        // the audio in memory is gone.
        endRecordingSpool(keepingAudio: true)
        isDictating = false
        appState?.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "interrupted")
        appState?.logger.log("DICTATION | interrupted")
        DiagnosticsTrail.record(
            logger: appState?.logger,
            level: .warning,
            engine: "dictation",
            event: "dictation_recording_interrupted",
            message: "Dictation recording was interrupted",
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000))"
                ]
            )
        )
        let runAction: () -> Void = { [weak self] in
            guard let self else { return }
            switch plan.action {
            case .transcribeCapturedAudio(let autoPaste):
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // An interrupted stop may still be awaiting a detached
                    // WAV write/cleanup. Readmit only after its owner exits,
                    // so an explicit retry cannot share that file mid-write.
                    _ = await DictationInterruptedAudioReadmission.run(DictationInterruptedAudioReadmission.Steps(
                        waitForInterruptedCheckpoint: { await interruptedCheckpointSignal?.wait() },
                        stillOwnsRecording: {
                            self.currentDictationSessionID == interruptedSessionID && !self.isDictating
                        },
                        hasRecoverableRecording: { self.appState?.sttRouter.hasRecoverableRecording == true },
                        audioGone: {
                            self.overlayController?.showError(
                                "The captured audio is no longer available. Start a new dictation.",
                                actionTitle: "Try Again",
                                action: { [weak self] in
                                    guard let self else { return }
                                    self.retryDictation(
                                        sourceApp: self.sessionSourceApp,
                                        anchorRect: self.sessionAnchorRect
                                    )
                                }
                            )
                        },
                        resetStopFence: { self.stopFinalizationGate.reset() },
                        readmit: {
                            // Not a microphone start: the App Nap label
                            // already says "stop finalization".
                            self.isDictating = true
                            self.overlayController?.state = .listening
                            self.overlayController?.markRetainedRecordingForEscape()
                            self.stopDictationAndPaste(trigger: .unknown, autoPaste: autoPaste)
                        }
                    ))
                }
            case .retryDictation:
                self.retryDictation(sourceApp: self.sessionSourceApp, anchorRect: self.sessionAnchorRect)
            }
        }
        // Fork: captured audio is saved right away instead of waiting on the
        // button. Upstream left it only in memory until the click; dismissing
        // the message left memory audio with no WAV, which blocks the next take
        // and Quit, and a force quit then lost it. This runs the button's own
        // path: WAV checkpoint, transcription, then a save to Dictations
        // without pasting (the focused app may have changed) and a Paste It
        // notice.
        if case .transcribeCapturedAudio = plan.action {
            appState?.logger.log("DICTATION | interrupted: saving the captured audio now")
            runAction()
            return
        }
        overlayController?.showError(plan.message, actionTitle: plan.actionTitle, action: runAction)
    }
}
