import XCTest
import AVFoundation
@testable import TranscriptedCore

/// A disk stall longer than the 8 MiB write queue can hold used to stop the
/// whole meeting. These tests pin the promise that it only costs the stretch
/// that didn't fit: the recording keeps going, the gap is padded with silence
/// so the track stays on the shared timeline, and later audio is saved.
final class WriteBacklogDropTests: XCTestCase {
    private static let monoFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private static let framesPerBuffer: AVAudioFrameCount = 8_192

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteBacklogDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeAudio(root: URL) -> Audio {
        Audio(paths: CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        ))
    }

    private func makeWriter(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
    }

    private func makeBuffer(marker: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.monoFormat, frameCapacity: Self.framesPerBuffer)!
        buffer.frameLength = Self.framesPerBuffer
        let samples = buffer.floatChannelData![0]
        for frame in 0..<Int(Self.framesPerBuffer) {
            samples[frame] = 0
        }
        samples[0] = marker
        return buffer
    }

    func testDiskStallPastTheQueueLimitDropsAudioPadsSilenceAndKeepsRecording() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        audio.realtimeAGC = nil
        let generation = audio.recordingSessionGeneration
        let writeContext = MicPCMWriteContext(
            generation: generation,
            monoFormat: Self.monoFormat,
            inputChannelCount: 1
        )
        let url = root.appendingPathComponent("mic.wav")
        let writer = try makeWriter(at: url, format: Self.monoFormat)
        XCTAssertTrue(audio.micAudioFileOwnership.installSessionWriter(writer, generation: generation).didInstall)

        // The disk stalls: nothing leaves the writer queue until released.
        let stalled = expectation(description: "writer queue stalled")
        let unstall = DispatchSemaphore(value: 0)
        defer { unstall.signal() }
        audio.micAudioFileQueue.async {
            stalled.fulfill()
            _ = unstall.wait(timeout: .now() + 10)
        }
        wait(for: [stalled], timeout: 1)

        let limit = audio.micAudioWriteBackpressure.byteLimit
        let bytesPerBuffer = Int(Self.framesPerBuffer) * MemoryLayout<Float>.size
        let admittedCount = limit / bytesPerBuffer
        let droppedCount = 40
        for index in 0..<(admittedCount + droppedCount) {
            audio.handleMicBuffer(makeBuffer(marker: index < admittedCount ? 0.25 : 0.9), writeContext: writeContext)
        }

        XCTAssertLessThanOrEqual(
            audio.micAudioWriteBackpressure.pendingBytesForTesting,
            limit,
            "dropping must keep the memory bound that the 8 MiB cap exists for"
        )
        XCTAssertEqual(audio.micAudioWriteBackpressure.totalDroppedFramesForTesting, droppedCount * Int(Self.framesPerBuffer))
        XCTAssertNil(audio.error, "a disk stall must not surface a stop")
        XCTAssertEqual(audio.recordingSessionGeneration, generation, "the recording was not stopped")

        // The disk comes back. Everything admitted drains, then later audio flows again.
        unstall.signal()
        audio.micAudioFileQueue.sync {}
        XCTAssertEqual(audio.micAudioWriteBackpressure.pendingBytesForTesting, 0)
        audio.handleMicBuffer(makeBuffer(marker: 0.5), writeContext: writeContext)
        audio.micAudioFileQueue.sync {}
        writer.close()

        let framesPerBuffer = Int(Self.framesPerBuffer)
        let expectedFrames = (admittedCount + droppedCount + 1) * framesPerBuffer
        let saved = try AVAudioFile(forReading: url)
        XCTAssertEqual(
            Int(saved.length),
            expectedFrames,
            "admitted audio, the padded gap and the audio after it must add up to the wall-clock length"
        )
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: AVAudioFrameCount(expectedFrames)))
        try saved.read(into: pcm)
        let samples = try XCTUnwrap(pcm.floatChannelData)[0]
        XCTAssertEqual(samples[0], 0.25, accuracy: 0.0001, "audio before the stall is intact")
        XCTAssertEqual(samples[(admittedCount - 1) * framesPerBuffer], 0.25, accuracy: 0.0001)
        let gapStart = admittedCount * framesPerBuffer
        let gapEnd = (admittedCount + droppedCount) * framesPerBuffer
        XCTAssertTrue(
            (gapStart..<gapEnd).allSatisfy { samples[$0] == 0 },
            "the dropped stretch is padded with digital silence, never with the dropped buffers' content"
        )
        XCTAssertEqual(samples[gapEnd], 0.5, accuracy: 0.0001, "audio after the stall is saved")

        let gaps = audio.recordingGaps
        XCTAssertEqual(gaps.count, 1, "the drop shows up in the saved meeting's health")
        let gap = try XCTUnwrap(gaps.first)
        XCTAssertEqual(
            gap.duration,
            Double(droppedCount * framesPerBuffer) / Self.monoFormat.sampleRate,
            accuracy: 0.001
        )
    }

    func testASuccessorRecordingNeverInheritsAPredecessorsGap() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let oldGeneration = audio.recordingSessionGeneration
        let gate = audio.micAudioWriteBackpressure
        XCTAssertEqual(
            gate.admitDroppingOnOverflow(bytes: gate.byteLimit + 1, frames: 480, generation: oldGeneration),
            .dropped(startsBurst: true)
        )

        audio.prepareForNewRecordingStart()

        XCTAssertEqual(gate.takePendingDroppedGap(generation: oldGeneration), .none)
        XCTAssertEqual(gate.takePendingDroppedGap(generation: audio.recordingSessionGeneration), .none)
        XCTAssertTrue(audio.recordingGaps.isEmpty)
    }

    func testPadMatchesTheWritersOwnFormatForAStereoSystemTrack() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let generation = audio.recordingSessionGeneration
        let stereo = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let url = root.appendingPathComponent("system.wav")
        let writer = try makeWriter(at: url, format: stereo)
        let dropped = 48_000 * 3 / 2

        audio.padDroppedAudio(.init(frames: dropped, isItemized: true), generation: generation, to: writer, source: .system)
        writer.close()

        let saved = try AVAudioFile(forReading: url)
        XCTAssertEqual(Int(saved.length), dropped, "1.5 s dropped means 1.5 s of silence, at the track's own rate")
        XCTAssertEqual(saved.processingFormat.channelCount, 2)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: saved.processingFormat, frameCapacity: AVAudioFrameCount(dropped)))
        try saved.read(into: pcm)
        let channels = try XCTUnwrap(pcm.floatChannelData)
        XCTAssertTrue((0..<dropped).allSatisfy { channels[0][$0] == 0 && channels[1][$0] == 0 })
        XCTAssertEqual(audio.recordingGaps.count, 1)
        XCTAssertEqual(audio.recordingGaps.first?.duration ?? 0, 1.5, accuracy: 0.001)
    }

    func testSilenceIsWrittenEvenWhenTheGapIsPastTheItemizedCap() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let url = root.appendingPathComponent("capped.wav")
        let writer = try makeWriter(at: url, format: Self.monoFormat)

        audio.padDroppedAudio(
            .init(frames: 4_800, isItemized: false),
            generation: audio.recordingSessionGeneration,
            to: writer,
            source: .microphone
        )
        writer.close()

        XCTAssertEqual(try AVAudioFile(forReading: url).length, 4_800, "alignment never depends on the cap")
        XCTAssertTrue(audio.recordingGaps.isEmpty, "only the health record is capped")
    }

    func testNothingIsPaddedWhenNothingWasDropped() throws {
        let root = try makeRoot()
        let audio = makeAudio(root: root)
        audio.prepareForNewRecordingStart()
        let url = root.appendingPathComponent("clean.wav")
        let writer = try makeWriter(at: url, format: Self.monoFormat)

        audio.padDroppedAudio(
            audio.micAudioWriteBackpressure.takePendingDroppedGap(generation: audio.recordingSessionGeneration),
            generation: audio.recordingSessionGeneration,
            to: writer,
            source: .microphone
        )
        writer.close()

        XCTAssertEqual(try AVAudioFile(forReading: url).length, 0)
        XCTAssertTrue(audio.recordingGaps.isEmpty)
    }
}
