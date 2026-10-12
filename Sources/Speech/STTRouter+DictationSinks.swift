import Foundation

/// Copies of a dictation take's audio for readers that run beside the take:
/// the island's live preview, and (fork) the on-disk spool and Breeze's
/// transcription in pieces. Every model records through the same Parakeet
/// capture; each copy is appended inside the same lock as the take's own
/// samples, on the capture queue, never the real-time thread.
extension STTRouter {
    /// Sends a copy of this dictation's mic audio to the island's live
    /// preview, or stops (nil).
    func setDictationPreviewSink(_ sink: DictationPreviewSampleSink?) {
        parakeetEngine.pendingSamplesLock.withLock { parakeetEngine.previewSink = sink }
    }

    /// Fork: attaches the take's on-disk spool feed to both places a take's
    /// audio arrives: the engine's own capture and a mic borrowed from a meeting.
    func setDictationRecordingSpoolSink(_ sink: DictationPreviewSampleSink?) {
        parakeetEngine.pendingSamplesLock.withLock { parakeetEngine.recordingSpoolSink = sink }
        parakeetEngine.sharedMeetingMicRecorder.setSpoolSink(sink)
    }

    /// Fork: the same two places for Breeze's live transcription
    /// (`BreezeLiveDictation`); WhisperEngine attaches it when a Breeze take
    /// starts and detaches it at Stop, cancel or a failed start.
    func setDictationChunkSink(_ sink: DictationPreviewSampleSink?) {
        parakeetEngine.pendingSamplesLock.withLock { parakeetEngine.dictationChunkSink = sink }
        parakeetEngine.sharedMeetingMicRecorder.setChunkSink(sink)
    }
}
