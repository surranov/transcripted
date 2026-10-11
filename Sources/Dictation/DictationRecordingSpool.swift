import Foundation

/// Writes a dictation to disk while it is still being recorded (fork).
///
/// Upstream kept a take only in memory until Stop, so a crash, a force quit or
/// a power cut mid-take lost all of it, up to the 15-minute cap. The spool
/// appends the take's 16 kHz audio every few seconds to the take's checkpoint
/// WAV (`DictationStoppedAudioRecoveryStore.checkpointURL`, with its JSON), so
/// a spool an earlier run left behind is just another leftover checkpoint:
/// `DictationLeftoverRecovery` transcribes and saves it at the next launch.
///
/// Ownership of that path is handed over exactly once, by `end`:
/// - Stop calls `end(keepingAudio: true)` before it writes its own checkpoint,
///   which then atomically replaces the spool's file, and the stop's usual
///   lifecycle (save, retire, keep on failure) takes over.
/// - An explicit discard calls `end(keepingAudio: false)`, which deletes what
///   the spool wrote.
/// `append` and `end` share one lock, so no spool write can land after `end`
/// returns: a late first append would otherwise create the file over the
/// stop's checkpoint and leave a few seconds where the whole take was.
///
/// The header's sizes are rewritten after each append, so a crash between the
/// two leaves a valid WAV holding everything up to the previous append. The
/// JSON is written only once the WAV holds audio, so a take that never got any
/// leaves nothing behind. A write failure stops the spool (logged by the
/// caller) and never touches the take itself, which still lives in memory.
final class DictationRecordingSpool: @unchecked Sendable {
    private enum State {
        case waitingForAudio
        case writing(FileHandle)
        case ended
    }

    let recovery: DictationStoppedAudioRecovery
    private let directory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var state = State.waitingForAudio
    private var dataByteCount: UInt32 = 0

    init(
        sessionID: UUID,
        createdAt: Date = Date(),
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let folder = directory ?? DictationStoppedAudioRecoveryStore.defaultDirectory
        self.directory = folder
        self.fileManager = fileManager
        recovery = DictationStoppedAudioRecovery(
            url: DictationStoppedAudioRecoveryStore.checkpointURL(sessionID: sessionID, directory: folder),
            sessionID: sessionID,
            createdAt: createdAt
        )
    }

    /// Bytes of audio on disk so far.
    var spooledByteCount: Int {
        lock.withLock { Int(dataByteCount) }
    }

    /// Appends `samples16k`. A no-op once `end` ran. On a failure the spool
    /// stops for good (what it wrote stays) and the error is rethrown once.
    func append(_ samples16k: [Float]) throws {
        guard !samples16k.isEmpty else { return }
        let pcm = DictationStoppedAudioRecoveryStore.pcm16Data(samples16k: samples16k)
        try lock.withLock {
            let handle: FileHandle
            switch state {
            case .ended:
                return
            case .writing(let open):
                handle = open
            case .waitingForAudio:
                do {
                    handle = try createFile()
                } catch {
                    state = .ended
                    throw error
                }
            }
            do {
                // The 4 GiB RIFF limit is ~37 h at 16 kHz; the take's cap is
                // 15 min. Stop spooling rather than wrap the sizes.
                guard UInt64(dataByteCount) + UInt64(pcm.count) <= UInt64(UInt32.max - 36) else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try handle.seekToEnd()
                try handle.write(contentsOf: pcm)
                let isFirstAudio = dataByteCount == 0
                dataByteCount += UInt32(pcm.count)
                try writeSizes(to: handle)
                if isFirstAudio {
                    try DictationStoppedAudioRecoveryStore.writeMetadata(for: recovery, fileManager: fileManager)
                }
            } catch {
                try? handle.close()
                state = .ended
                throw error
            }
        }
    }

    /// Hands the checkpoint path over. `keepingAudio` leaves what was written
    /// (Stop, a quit, an interruption, a new take); otherwise it is deleted
    /// (an explicit discard). Only the first call does anything.
    func end(keepingAudio: Bool) {
        lock.withLock {
            let wroteFile: Bool
            switch state {
            case .ended:
                return
            case .waitingForAudio:
                wroteFile = false
            case .writing(let handle):
                try? handle.close()
                wroteFile = true
            }
            state = .ended
            guard !keepingAudio, wroteFile else { return }
            try? fileManager.removeItem(at: DictationStoppedAudioRecoveryStore.metadataURL(for: recovery.url))
            try? fileManager.removeItem(at: recovery.url)
        }
    }

    private func createFile() throws -> FileHandle {
        try fileManager.createPrivateDirectory(at: directory)
        // A file already here has this take's session id: an earlier spool of
        // the same take can't exist, so it's a stale leftover and is replaced.
        guard fileManager.createFile(
            atPath: recovery.url.path,
            contents: DictationStoppedAudioRecoveryStore.wavHeader(dataByteCount: 0),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: recovery.url)
        state = .writing(handle)
        return handle
    }

    private func writeSizes(to handle: FileHandle) throws {
        try handle.seek(toOffset: DictationStoppedAudioRecoveryStore.wavRIFFSizeOffset)
        try handle.write(contentsOf: Self.littleEndianBytes(36 + dataByteCount))
        try handle.seek(toOffset: DictationStoppedAudioRecoveryStore.wavDataSizeOffset)
        try handle.write(contentsOf: Self.littleEndianBytes(dataByteCount))
    }

    private static func littleEndianBytes(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}

/// Feeds a `DictationRecordingSpool` from the take's live 16 kHz audio every
/// `interval` until it is cancelled. `takeSamples` returns what was captured
/// since its last call; it is called only from this loop, one call at a time.
enum DictationRecordingSpoolPump {
    static let interval: Duration = .seconds(3)

    static func run(
        _ spool: DictationRecordingSpool,
        interval: Duration = interval,
        takeSamples: @Sendable () -> [Float],
        reportFailure: @Sendable (Error) -> Void
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: interval)
            if Task.isCancelled { return }
            do {
                try spool.append(takeSamples())
            } catch {
                reportFailure(error)
                return
            }
        }
    }
}
