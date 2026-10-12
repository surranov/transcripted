// WhisperCppTranscriber.swift
// Fork: one whisper.cpp model (Breeze-ASR-25) loaded in the app, for
// WhisperEngine's Breeze choice. whisper.cpp comes from
// scripts/fork/build-whisper-cpp.sh; a build without it compiles this file as
// a stub that reports the model as unavailable instead of failing to link.

import Foundation
#if canImport(WhisperCpp)
import WhisperCpp
#endif

/// Set from any thread to stop the whisper.cpp call that reads it; checked
/// by whisper.cpp between decoder steps through its abort callback.
final class WhisperCppCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum WhisperCppError: LocalizedError {
    case unavailableInThisBuild
    case notLoaded
    case loadFailed
    case transcriptionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailableInThisBuild:
            return "This build has no whisper.cpp. Run scripts/fork/build-whisper-cpp.sh and rebuild."
        case .notLoaded:
            return "The whisper.cpp model is not loaded."
        case .loadFailed:
            return "whisper.cpp couldn't load the model files."
        case .transcriptionFailed(let code):
            return "whisper.cpp transcription failed (code \(code))."
        }
    }
}

/// One piece of 16 kHz audio in, its text out; `BreezeLiveDictation` talks
/// to whisper.cpp only through this, so its piece logic runs in tests with a
/// fake.
protocol BreezePieceTranscribing: AnyObject, Sendable {
    func transcribe(
        _ samples: [Float],
        language: String?,
        prompt: String,
        cancellation: WhisperCppCancellation
    ) async throws -> String
}

/// What whisper.cpp's abort callback reads: the call's own cancellation and
/// the model's unload.
final class WhisperCppAbortProbe: @unchecked Sendable {
    private let tokens: [WhisperCppCancellation]
    init(_ tokens: [WhisperCppCancellation]) { self.tokens = tokens }
    var shouldAbort: Bool { tokens.contains { $0.isCancelled } }
}

/// Every whisper.cpp call runs on one serial queue, never the main thread:
/// loading takes seconds (the Core ML encoder compiles on first use) and a
/// transcription blocks until it's done. One queue also means a dictation
/// piece and a meeting segment never decode at the same time on one context.
final class WhisperCppTranscriber: BreezePieceTranscribing, @unchecked Sendable {
    static var isAvailableInThisBuild: Bool {
        #if canImport(WhisperCpp)
        return true
        #else
        return false
        #endif
    }

    private let queue = DispatchQueue(label: "com.transcripted.whispercpp", qos: .userInitiated)
    /// Only touched on `queue`.
    private var context: OpaquePointer?
    private let stateLock = NSLock()
    private var loaded = false
    /// Stops whatever is decoding when the model goes away; a new one per load.
    private var unloadToken = WhisperCppCancellation()

    var isLoaded: Bool { stateLock.withLock { loaded } }

    /// CPU threads for the parts Metal and Core ML don't run. whisper.cpp's
    /// own default is 4; more barely helps once the GPU decodes.
    private static let threadCount = Int32(min(8, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))

    func load(weightsURL: URL) async throws {
        #if canImport(WhisperCpp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                Self.silenceLibraryLogging()
                if let existing = context {
                    whisper_free(existing)
                    context = nil
                    stateLock.withLock { loaded = false }
                }
                stateLock.withLock { unloadToken = WhisperCppCancellation() }
                var params = whisper_context_default_params()
                params.use_gpu = true
                guard let created = weightsURL.path.withCString({ whisper_init_from_file_with_params($0, params) }) else {
                    continuation.resume(throwing: WhisperCppError.loadFailed)
                    return
                }
                context = created
                stateLock.withLock { loaded = true }
                continuation.resume()
            }
        }
        #else
        throw WhisperCppError.unavailableInThisBuild
        #endif
    }

    /// Stops any decode in progress and frees the model. Quitting passes
    /// `waitUntilFreed`: ggml's Metal backend asserts at process exit if a
    /// context is still alive, so the free must finish first. Otherwise the
    /// free just queues behind the current call: a model switch on the main
    /// thread must not wait out a first load that compiles the Core ML encoder.
    func unload(waitUntilFreed: Bool = false) {
        let token = stateLock.withLock { () -> WhisperCppCancellation in
            loaded = false
            return unloadToken
        }
        token.cancel()
        #if canImport(WhisperCpp)
        let free = { [self] in
            if let existing = context {
                whisper_free(existing)
                context = nil
            }
        }
        if waitUntilFreed { queue.sync(execute: free) } else { queue.async(execute: free) }
        #endif
    }

    /// Transcribes 16 kHz mono samples. `language` nil lets the model detect
    /// it; `prompt` is the text Whisper treats as coming right before this
    /// audio. Cancelling the Swift task, or `cancellation`, stops the decode.
    func transcribe(
        _ samples: [Float],
        language: String?,
        prompt: String,
        cancellation: WhisperCppCancellation = WhisperCppCancellation()
    ) async throws -> String {
        #if canImport(WhisperCpp)
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async { [self] in
                    guard let context else {
                        continuation.resume(throwing: WhisperCppError.notLoaded)
                        return
                    }
                    guard !cancellation.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let unloading = stateLock.withLock { unloadToken }
                    let status = Self.runFull(
                        context: context,
                        samples: samples,
                        language: language,
                        prompt: prompt,
                        probe: WhisperCppAbortProbe([cancellation, unloading])
                    )
                    if cancellation.isCancelled || unloading.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if status != 0 {
                        continuation.resume(throwing: WhisperCppError.transcriptionFailed(status))
                    } else {
                        continuation.resume(returning: Self.collectText(context))
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        #else
        throw WhisperCppError.unavailableInThisBuild
        #endif
    }

    #if canImport(WhisperCpp)
    private static func runFull(
        context: OpaquePointer,
        samples: [Float],
        language: String?,
        prompt: String,
        probe: WhisperCppAbortProbe
    ) -> Int32 {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = threadCount
        params.translate = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.detect_language = false
        // No "[BLANK_AUDIO]", "(music)" and the like for a breath or a key
        // click at the end of a take.
        params.suppress_nst = true
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<WhisperCppAbortProbe>.fromOpaque(userData).takeUnretainedValue().shouldAbort
        }
        let token = Unmanaged.passRetained(probe)
        defer { token.release() }
        params.abort_callback_user_data = token.toOpaque()

        // whisper.cpp reads both strings only during whisper_full.
        return (language ?? "auto").withCString { languagePointer in
            prompt.withCString { promptPointer in
                params.language = languagePointer
                params.initial_prompt = prompt.isEmpty ? nil : promptPointer
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
    }

    private static func collectText(_ context: OpaquePointer) -> String {
        var text = ""
        for index in 0..<whisper_full_n_segments(context) {
            if let segment = whisper_full_get_segment_text(context, index) {
                text += String(cString: segment)
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// whisper.cpp and ggml print model details, timings and file paths to
    /// stderr by default; none of it may reach a log (no paths off the
    /// device, and nothing that could carry text).
    private static let silenceOnce: Void = {
        whisper_log_set({ _, _, _ in }, nil)
    }()

    private static func silenceLibraryLogging() { _ = silenceOnce }
    #endif
}
