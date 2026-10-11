import AVFoundation
import Combine
import FluidAudio
import XCTest
@testable import TranscriptedCore

/// Launch recovery is where segments a failed Stop merge left behind come
/// back as audio the user can retry. These tests pin that a journal naming a
/// failed merge is merged again (never trusted as "primary is the meeting"),
/// that it waits while a transcription owns the audio, and that it is kept
/// while segments with audio still can't be merged.
@available(macOS 14.0, *)
@MainActor
final class MergeFailureRecoveryTests: XCTestCase {
    private var tempDirectory: URL!
    private var immutableURLs: [URL] = []

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeFailureRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in immutableURLs {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        }
        immutableURLs = []
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
    }

    func testRecoveryMergesAgainAfterAFailedStopMergeSoTheRowCoversEverySegment() async throws {
        let (manager, paths) = makeManager()
        let primary = try writeMonoWAV(in: paths.audioCaptures, named: "meeting_mic.wav", frames: 16_000)
        let recovery = try writeMonoWAV(in: paths.audioCaptures, named: "meeting_mic_recovery.wav", frames: 32_000)
        let journalURL = try writeFinalizedJournal(
            in: paths.audioCaptures,
            primary: primary,
            segments: [.init(filename: primary.lastPathComponent, gapBefore: 0), .init(filename: recovery.lastPathComponent, gapBefore: 0)],
            mergeFailed: true
        )

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )

        XCTAssertEqual(recovered, 1)
        let row = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(row.micAudioURL.lastPathComponent, "meeting_mic_merged.wav", "the primary alone is only part of the meeting")
        XCTAssertEqual(try AVAudioFile(forReading: row.micAudioURL).length, 48_000, "both segments are in the recovered audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path), "everything is merged, so the journal is done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testRecoveryKeepsTheJournalWhileSegmentsWithAudioStillCannotBeMerged() async throws {
        let (manager, paths) = makeManager()
        let primary = try writeMonoWAV(in: paths.audioCaptures, named: "meeting_mic.wav", frames: 16_000)
        let recovery = try writeMonoWAV(in: paths.audioCaptures, named: "meeting_mic_recovery.wav", frames: 32_000)
        let journalURL = try writeFinalizedJournal(
            in: paths.audioCaptures,
            primary: primary,
            segments: [.init(filename: primary.lastPathComponent, gapBefore: 0), .init(filename: recovery.lastPathComponent, gapBefore: 0)],
            mergeFailed: true
        )
        try blockMergedOutput(for: primary, in: paths.audioCaptures)

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )

        XCTAssertEqual(recovered, 1, "the primary is still handed to the user as a retryable row")
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.first?.micAudioURL.lastPathComponent, "meeting_mic.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path), "the journal still lists a segment the row doesn't cover")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
    }

    func testRecoveryDoesNotMergeAudioATranscriptionIsUsing() async throws {
        let (manager, paths) = makeManager()
        let primary = try writeMonoWAV(in: paths.audioCaptures, named: "meeting_mic.wav", frames: 16_000)
        let recovery = try writeMonoWAV(in: paths.audioCaptures, named: "meeting_mic_recovery.wav", frames: 16_000)
        let journalURL = try writeFinalizedJournal(
            in: paths.audioCaptures,
            primary: primary,
            segments: [.init(filename: primary.lastPathComponent, gapBefore: 0), .init(filename: recovery.lastPathComponent, gapBefore: 0)],
            mergeFailed: true
        )
        // The queued or running job reads `primary`; a merge deletes its sources.
        manager.reservedAudioURLsProvider = { [primary] }

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )

        XCTAssertEqual(recovered, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primary.path), "the owner's audio is untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
    }

    func testRecoveryOfALeftoverSegmentAfterTheSavedMeetingBecomesARetryableRow() async throws {
        // The common case: the stop merge failed, the primary was transcribed
        // and its scratch removed. The retained journal now finds only the
        // later segment, which was never transcribed.
        let (manager, paths) = makeManager()
        let primaryName = "meeting_mic.wav"
        let recovery = try writeMonoWAV(in: paths.audioCaptures, named: "meeting_mic_recovery.wav", frames: 32_000)
        let journalURL = try writeFinalizedJournal(
            in: paths.audioCaptures,
            primary: paths.audioCaptures.appendingPathComponent(primaryName),
            segments: [.init(filename: primaryName, gapBefore: 0), .init(filename: recovery.lastPathComponent, gapBefore: 0)],
            mergeFailed: true
        )

        let recovered = await manager.recoverOrphanedRecordings(
            in: paths.audioCaptures,
            livenessWindow: 0,
            waitForRecentJournals: false
        )

        XCTAssertEqual(recovered, 1)
        let row = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertEqual(row.micAudioURL.lastPathComponent, recovery.lastPathComponent)
        XCTAssertTrue(row.isRetryable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path), "a single leftover segment is fully covered by its row")
    }

    // MARK: - Fixtures

    private func makeManager() -> (TranscriptionTaskManager, CoreStoragePaths) {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )
        try? FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.speakerClips, withIntermediateDirectories: true)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: MergeRecoveryStubSpeechToTextEngine(),
            diarization: MergeRecoveryStubDiarizationEngine(),
            speakerStore: SpeakerDatabase(path: paths.speakerDB.path),
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips]
        )
        return (manager, paths)
    }

    private func blockMergedOutput(for primary: URL, in directory: URL) throws {
        let blocked = directory.appendingPathComponent(
            primary.deletingPathExtension().lastPathComponent + "_merged.wav",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocked.path)
        immutableURLs.append(blocked)
    }

    private func writeFinalizedJournal(
        in directory: URL,
        primary: URL,
        segments: [MeetingRecordingJournal.SegmentRecord],
        mergeFailed: Bool
    ) throws -> URL {
        let startedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let journal = MeetingRecordingJournal(
            version: 1,
            state: .finalized,
            startedAt: startedAt,
            updatedAt: startedAt,
            primaryMicFilename: primary.lastPathComponent,
            micSegments: segments,
            systemAudioFilename: nil,
            finalMicFilename: primary.lastPathComponent,
            micMergeFailed: mergeFailed ? true : nil
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent(
            primary.deletingPathExtension().lastPathComponent + MeetingRecordingJournalStore.filenameSuffix
        )
        try encoder.encode(journal).write(to: url, options: .atomic)
        return url
    }

    private func writeMonoWAV(in directory: URL, named name: String, frames: Int, sampleRate: Double = 16_000) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<frames { samples[index] = 0.25 }
        try file.write(from: buffer)
        file.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3_600)],
            ofItemAtPath: url.path
        )
        return url
    }
}

@available(macOS 14.0, *)
@MainActor
private final class MergeRecoveryStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true

    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String { "" }
    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class MergeRecoveryStubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true

    func initialize() async {}
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { [] }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { [] }
    func cleanup() {}
}
