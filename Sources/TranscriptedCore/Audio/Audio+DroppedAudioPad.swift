import Foundation
import Darwin
@preconcurrency import AVFoundation

/// Which saved track lost audio to a write backlog.
enum DroppedAudioSource: String {
    case microphone
    case system
}

extension Audio {
    /// Longest silence a single catch-up pad writes. A disk that stalls for
    /// longer than this still loses the excess, but the file never grows by an
    /// unbounded amount in one write.
    static let maxDroppedAudioPadSeconds: TimeInterval = 600
    private static let droppedAudioPadChunkSeconds: TimeInterval = 1

    /// Pads the stretch of audio a write backlog dropped, so the track keeps
    /// its place on the shared timeline with the other track.
    ///
    /// `gap` is what the producer took from the gate (`takePendingDroppedGap`)
    /// when it admitted the buffer that follows the gap. Taking it there, on the
    /// producer's thread, pins the gap to its place in arrival order: the
    /// writer may still be draining older buffers when the drop happens, and
    /// the silence must land after them, not ahead of them. This runs on the
    /// stream's serial writer queue (never in an audio callback), right before
    /// that following buffer is written. A pad that fails to write is logged
    /// and skipped; the buffer after it is still written and the recording
    /// goes on.
    func padDroppedAudio(
        _ gap: PCMBufferBackpressureGate.DroppedGap,
        generation: UInt64,
        to writer: AVAudioFile,
        source: DroppedAudioSource
    ) {
        let droppedFrames = gap.frames
        guard droppedFrames > 0 else { return }

        let format = writer.processingFormat
        let sampleRate = format.sampleRate
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate), format.channelCount > 0 else {
            AppLogger.audioMic.warning("Dropped audio could not be padded: unusable writer format", [
                "source": source.rawValue
            ])
            return
        }

        let droppedSeconds = Double(droppedFrames) / sampleRate
        let padFrames = min(droppedFrames, Int((Self.maxDroppedAudioPadSeconds * sampleRate).rounded()))
        let written = Self.writeSilence(frames: padFrames, to: writer, chunkSeconds: Self.droppedAudioPadChunkSeconds)

        // The silence is always written. The health record and the log are
        // capped per recording (`PCMBufferBackpressureGate.maxItemizedGaps`) so
        // a disk that hovers at the limit can't grow them without bound.
        guard gap.isItemized else { return }
        // Only a live recording owns the gap list; a tail write after Stop must
        // not add to a successor's health.
        if recordingSessionGeneration == generation {
            appendRecordingGap(AudioGap(
                start: Date(timeIntervalSinceNow: -droppedSeconds),
                duration: droppedSeconds,
                reason: source == .microphone ? "Mic audio dropped (disk backlog)" : "System audio dropped (disk backlog)"
            ))
        }
        let context = [
            "source": source.rawValue,
            "droppedSeconds": String(format: "%.1f", droppedSeconds),
            "paddedSeconds": String(format: "%.1f", Double(written) / sampleRate)
        ]
        if written == droppedFrames {
            AppLogger.audio.warning("Padded audio dropped while the disk was backed up", context)
        } else {
            AppLogger.audio.error("Audio dropped while the disk was backed up was only partly padded", context)
        }
    }

    /// Writes `frames` of digital silence in `writer`'s own format, in
    /// `chunkSeconds` pieces so one pad never allocates a whole stall at once.
    /// Returns how many frames actually landed; a write failure stops early.
    static func writeSilence(frames: Int, to writer: AVAudioFile, chunkSeconds: TimeInterval) -> Int {
        let format = writer.processingFormat
        let chunkFrames = max(1, Int((chunkSeconds * format.sampleRate).rounded()))
        var remaining = frames
        var written = 0
        while remaining > 0 {
            let count = min(remaining, chunkFrames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                break
            }
            buffer.frameLength = AVAudioFrameCount(count)
            if let channels = buffer.floatChannelData {
                let channelCount = format.isInterleaved ? 1 : Int(format.channelCount)
                let samplesPerChannel = format.isInterleaved ? count * Int(format.channelCount) : count
                for channel in 0..<channelCount {
                    memset(channels[channel], 0, samplesPerChannel * MemoryLayout<Float>.size)
                }
            }
            do {
                try writer.write(from: buffer)
            } catch {
                break
            }
            written += count
            remaining -= count
        }
        return written
    }
}
