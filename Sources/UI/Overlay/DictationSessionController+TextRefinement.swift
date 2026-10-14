// DictationSessionController+TextRefinement.swift
// Fork: the transcript LLM pass before paste, and Esc after an admitted stop.

import AppKit

extension DictationSessionController {
    /// The local transcript LLM pass (`Sources/TranscriptLLM/`, reached only
    /// through `DictationTextRefiner`); `text(original:)` on the result is the
    /// text to deliver.
    ///
    /// Never costs the take: a skip, a failure, a rejected answer or Esc all
    /// deliver `text` unchanged. The pass runs in its own task so Esc can stop
    /// waiting on it (`keepStoppedTakeWithoutPasting`) without cancelling the
    /// stop task, which still has to save the take. Cancelling the stop task
    /// itself (a newer session, Quit) cancels the pass too.
    func refineDictationText(
        _ text: String,
        appState: TranscriptedAppState,
        sessionID: UUID
    ) async -> DictationTextRefinement {
        // Esc during transcription already declined the paste: save the
        // transcript now rather than wait on the model.
        guard !pasteDeclinedSessionIDs.contains(sessionID), !Task.isCancelled else { return .unchanged(.cancelled) }
        let refiner: any DictationTextRefiner = appState.transcriptLLM
        let task = Task { @MainActor in await refiner.refine(text) }
        transcriptRefinementTask = task
        defer {
            if transcriptRefinementTask == task { transcriptRefinementTask = nil }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Esc after the stop was admitted. The audio is already a WAV checkpoint
    /// and the transcript is on its way, so throwing both away (what Esc did
    /// before) loses a take the user may not have meant to lose. Instead Esc
    /// declines the paste: the take finishes, is saved to Dictations with a
    /// Paste It notice, and its audio follows the normal keep rule. Meetings
    /// already keep audio on cancel-during-transcription for the same reason.
    ///
    /// True when this Esc was handled here; false sends it down the regular
    /// cancel path (no stop admitted yet: nothing is on disk to keep).
    func keepStoppedTakeWithoutPasting() -> Bool {
        guard isDictating,
              stopFinalizationGate.admittedSessionID == currentDictationSessionID else { return false }
        // Esc on a finishing take means stop, not "and start the next one".
        dropQueuedDictationStart(showMessage: false)
        guard !pasteDeclinedSessionIDs.contains(currentDictationSessionID) else { return true }
        pasteDeclinedSessionIDs.insert(currentDictationSessionID)
        transcriptRefinementTask?.cancel()
        appState?.logger.log("DICTATION | Esc after stop: keeping the take, saving it without pasting")
        // The overlay stays as it is (switching it to `.loading` would change
        // how the next key press is routed); the save shows the Paste It
        // notice when it lands.
        return true
    }
}
