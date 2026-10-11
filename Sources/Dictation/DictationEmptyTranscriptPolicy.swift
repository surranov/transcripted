import Foundation

/// What a dictation take that came back with no text should do.
///
/// `DictationSessionController.stopDictationAndPaste` asks this once it knows
/// why the text is empty, then runs the matching UI; tests call it directly.
/// First match wins:
///
/// 1. A quick, too-short press is a mis-tap: close like a cancel, no error.
/// 2. No speech worth keeping: show the no-speech note, then drop the audio.
/// 3. Probably a wrong-language guess with text held back: offer Paste Anyway,
///    and keep the audio in case the guess was wrong.
/// 4. The audio is saved and the take was long (see
///    `DictationFailedTakePolicy`): say why and offer to transcribe it.
/// 5. The audio is saved but the take was short: say why and keep the WAV
///    (fork). Upstream dropped it ("saying it again is quicker"), but the
///    words were said and the failure (a model that didn't load, audio that
///    needed recovery) may not repeat: the next launch transcribes it again
///    (`DictationLeftoverRecovery`).
/// 6. Audio that needs recovery but has no saved WAV: offer the no-paste
///    checkpoint retry instead of calling it empty speech.
/// 7. Otherwise: just say why.
///
/// Nothing offers a recording after its message closes. The next launch
/// transcribes what's left and saves it to Dictations
/// (`DictationLeftoverRecovery`).
enum DictationEmptyTranscriptPolicy {
    enum Action: Equatable {
        case closeLikeCancel
        case showNoSpeechAndDismiss
        case offerPasteAnyway
        case offerSavedRecording
        case offerCheckpointRetry
        case showMessage
    }

    struct Decision: Equatable {
        var action: Action
        /// Friction telemetry counts a mis-tap as cancelled, everything else as a give-up.
        var countsAsCancelled: Bool
        /// Delete the stopped-audio checkpoint once the take is closed.
        var discardsSavedRecording: Bool
    }

    static func decide(
        reason: DictationEmptyTranscriptionReason,
        pressDuration: TimeInterval,
        hasHeldBackText: Bool,
        hasSavedRecording: Bool,
        audioStillInMemory: Bool
    ) -> Decision {
        let isMisTap = reason.isAccidentalStart(pressDuration: pressDuration)
        let action: Action
        var discardsSavedRecording = reason.shouldDiscardStoppedAudioRecovery
        if isMisTap {
            action = .closeLikeCancel
        } else if reason.shouldDiscardStoppedAudioRecovery {
            action = .showNoSpeechAndDismiss
        } else if reason == .otherLanguage, hasHeldBackText {
            action = .offerPasteAnyway
        } else if hasSavedRecording {
            if DictationFailedTakePolicy.keepsSavedRecording(takeLength: pressDuration) {
                action = .offerSavedRecording
            } else {
                action = .showMessage
                discardsSavedRecording = false
            }
        } else if reason == .audioNeedsRecovery {
            action = .offerCheckpointRetry
        } else {
            action = .showMessage
        }
        return Decision(
            action: action,
            countsAsCancelled: isMisTap,
            discardsSavedRecording: discardsSavedRecording
        )
    }
}

/// Which message a dictation that failed after its audio was saved gets. A
/// long take is hard to repeat word for word, so its message offers
/// Transcribe It (the meeting importer) while it is on screen. A short one
/// gets a plain message; its audio stays too (fork) and the next launch
/// transcribes it (`DictationLeftoverRecovery`).
enum DictationFailedTakePolicy {
    /// In the field (60 days to 2026-10-04), 42 of 46 takes that came back
    /// empty over real audio were under 30 s.
    static let minimumLengthToKeep: TimeInterval = 30

    /// `takeLength` is from the start of the take to the stop request.
    static func keepsSavedRecording(takeLength: TimeInterval) -> Bool {
        takeLength >= minimumLengthToKeep
    }

    /// Whether a short take's WAV can be deleted now. Not while the take's
    /// audio is still in memory: without the WAV, that audio would block the
    /// next take and Quit until Retry Saving rewrote it.
    static func canDropSavedRecording(audioStillInMemory: Bool) -> Bool {
        !audioStillInMemory
    }
}
