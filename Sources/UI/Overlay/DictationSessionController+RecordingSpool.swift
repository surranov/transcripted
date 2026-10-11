import Foundation

/// Fork: keeps the take's audio on disk while it records
/// (`DictationRecordingSpool`), so a crash, force quit or power cut mid-take
/// leaves a checkpoint that launch recovery turns into a saved Dictation.
///
/// `startDictation` begins one per take. Every way a take leaves recording ends
/// it: Stop (keeps; its own checkpoint replaces the file), an explicit discard
/// (deletes), a quit or an interruption (keep), and the next take's start
/// (keeps, for a take that ended some other way, such as a failed start).
extension DictationSessionController {
    /// Unread audio the feed holds before it drops it, if the disk or the
    /// feeding task stalls this long. The feed is read every few seconds.
    private static let recordingSpoolFeedCapacitySeconds: Double = 120

    func beginRecordingSpool(sessionID: UUID) {
        endRecordingSpool(keepingAudio: true)
        guard let appState else { return }
        let feed = DictationPreviewSampleSink(capacitySeconds: Self.recordingSpoolFeedCapacitySeconds)
        let spool = DictationRecordingSpool(sessionID: sessionID)
        appState.sttRouter.setDictationRecordingSpoolSink(feed)
        recordingSpool = spool
        recordingSpoolTask = Task.detached(priority: .utility) { [weak self] in
            await DictationRecordingSpoolPump.run(
                spool,
                takeSamples: { feed.take() },
                reportFailure: { error in
                    // The take itself still lives in memory; only the crash
                    // copy stops. No paths or text in the log.
                    let code = (error as NSError).code
                    Task { @MainActor in
                        self?.appState?.logger.log("DICTATION | recording spool stopped after a write failure (code \(code)); the take continues in memory")
                    }
                }
            )
        }
    }

    /// Hands the take's checkpoint path over; see `DictationRecordingSpool.end`.
    /// Synchronous on purpose: Stop calls it before its checkpoint write
    /// starts, so no spool write can land on top of that checkpoint.
    func endRecordingSpool(keepingAudio: Bool) {
        appState?.sttRouter.setDictationRecordingSpoolSink(nil)
        recordingSpoolTask?.cancel()
        recordingSpoolTask = nil
        recordingSpool?.end(keepingAudio: keepingAudio)
        recordingSpool = nil
    }
}
