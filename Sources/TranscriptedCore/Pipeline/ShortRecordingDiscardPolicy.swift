import Foundation

/// Guards the live-capture "too short" gate in `startTranscription`, which is
/// the one place a recording is deleted without being queued for retry.
///
/// The gate measures length with `AVAudioFile.length`, which trusts the WAV
/// header. A writer that never finalized its header declares an empty data
/// chunk, so a whole meeting reads as ~0 s and was deleted as an "accidental
/// start". Two layers keep that from happening:
/// 1. the gate repairs unfinalized headers before it measures (the same
///    `WAVHeaderRepair` the merger, orphan recovery and failed-queue load use);
/// 2. whatever the header says, a file too large to be a hotkey bump is never
///    deleted here; it goes to the failed queue instead.
enum ShortRecordingDiscardPolicy {
    /// Largest capture file the gate may still delete. A real accidental start
    /// is under 2 s: 768 KB of 48 kHz stereo float32 (the system track, the
    /// widest format we record), 384 KB for the mono mic. Anything above 1 MiB
    /// holds more audio than the header admits, so the length reading can't
    /// be trusted.
    static let maximumDiscardableBytes = 1_048_576

    /// Whether every capture file is small enough to delete. `nil` is a file
    /// whose size could not be read: unknown size is never deleted.
    static func mayDiscard(fileSizes: [Int?]) -> Bool {
        fileSizes.allSatisfy { size in
            guard let size else { return false }
            return size <= maximumDiscardableBytes
        }
    }

    static func fileSize(at url: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// Patches an unfinalized WAV header in place so the length reads true.
    /// Best effort: a file that isn't a parseable PCM WAV is left alone and the
    /// size guard above covers it.
    static func repairUnfinalizedHeader(at url: URL) {
        guard url.pathExtension.lowercased() == "wav" else { return }
        do {
            if try WAVHeaderRepair.repairIfNeeded(at: url) {
                AppLogger.pipeline.warning("Repaired unfinalized capture WAV header before the length check", [
                    "file": url.lastPathComponent
                ])
            }
        } catch {
            // Missing, truncated or non-WAV file: the length check and the
            // size guard decide what happens to it.
        }
    }
}
