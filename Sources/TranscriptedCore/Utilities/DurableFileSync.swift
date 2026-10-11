import Foundation
import Darwin

/// What a durability barrier can promise about a file or directory.
enum FileSyncOutcome: Equatable {
    /// The data reached stable storage.
    case synced
    /// The volume can't be flushed this way (some network and FAT volumes
    /// reject it). Nothing more can be done; callers treat it as done.
    case unsupported
    /// The flush failed (I/O error, missing path). The data may be lost on a
    /// crash, so callers must keep whatever else still holds the meeting.
    case failed

    var isSafeToRelyOn: Bool { self != .failed }
}

/// Seam for the barrier, so tests can record when it runs and make it fail.
protocol FileDurability {
    func syncFile(at url: URL) -> FileSyncOutcome
    /// Flushes a directory entry (a new or renamed file inside it).
    func syncDirectory(at url: URL) -> FileSyncOutcome
}

/// Flushes a saved transcript or retained audio all the way to the drive
/// before the app deletes what could rebuild it (the recording journal and the
/// scratch audio).
///
/// `write(atomically:)` and `copyItem` only hand data to the OS, and plain
/// `fsync` on macOS stops at the drive's own write cache. `F_FULLFSYNC` is what
/// actually forces the cache out, so it goes first, with `fsync` as the
/// fallback on volumes that reject it. Slow by design (hundreds of ms to a few
/// seconds for a long recording): call it from a background queue only.
struct DurableFileSync: FileDurability {
    func syncFile(at url: URL) -> FileSyncOutcome {
        flush(path: url.path, directory: false)
    }

    func syncDirectory(at url: URL) -> FileSyncOutcome {
        flush(path: url.path, directory: true)
    }

    private func flush(path: String, directory: Bool) -> FileSyncOutcome {
        let descriptor = Darwin.open(path, directory ? (O_RDONLY | O_DIRECTORY) : O_RDONLY)
        guard descriptor >= 0 else {
            return Self.outcome(forErrno: errno)
        }
        defer { Darwin.close(descriptor) }

        if fcntl(descriptor, F_FULLFSYNC) == 0 { return .synced }
        // The volume refused the full flush. A plain fsync is the next best
        // thing, and its own failure decides the outcome.
        if Darwin.fsync(descriptor) == 0 { return .synced }
        return Self.outcome(forErrno: errno)
    }

    /// Codes that mean "this volume has no flush", not "the flush failed".
    static func outcome(forErrno code: Int32) -> FileSyncOutcome {
        switch code {
        case ENOTSUP, EINVAL, ENOTTY:
            return .unsupported
        default:
            return .failed
        }
    }
}

/// The barrier the savers use. Production code never touches it; tests swap
/// it (`withOverride`) to record when the barrier runs or to make it fail.
enum SavedFileDurability {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: (any FileDurability)?

    static var current: any FileDurability {
        lock.lock()
        defer { lock.unlock() }
        return override ?? DurableFileSync()
    }

    static func withOverride<T>(_ durability: any FileDurability, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        override = durability
        lock.unlock()
        defer {
            lock.lock()
            override = nil
            lock.unlock()
        }
        return try body()
    }
}
