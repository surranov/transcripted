// DictationTranscriptionLine.swift
// Fork: the dictation queue. Detached takes are transcribed one at a time,
// in the order they stopped (`STTRouter+DetachedDictation.swift`). Parakeet's
// decoder and whisper.cpp each run one call at a time anyway; the line keeps
// a take's focused retry next to its first pass and its words in take order.

import Foundation

@MainActor
final class DictationTranscriptionLine {
    private var tail: Task<Void, Never>?
    /// Jobs queued or running.
    private(set) var count = 0

    /// Runs `work` once every job enqueued before it has ended. Cancelling
    /// the caller cancels this job only; the jobs behind it still run, after
    /// it ends (a cancelled job still waits its turn before it returns, so
    /// the line never runs two at once).
    func run<Value: Sendable>(_ work: @escaping @MainActor () async -> Value) async -> Value {
        count += 1
        defer { count -= 1 }
        let previous = tail
        let job = Task { @MainActor () -> Value in
            await previous?.value
            return await work()
        }
        tail = Task { _ = await job.value }
        return await withTaskCancellationHandler {
            await job.value
        } onCancel: {
            job.cancel()
        }
    }
}
