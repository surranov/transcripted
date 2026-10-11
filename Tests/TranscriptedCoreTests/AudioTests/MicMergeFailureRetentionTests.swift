import XCTest
import AVFoundation
@testable import TranscriptedCore

/// When Stop cannot merge the mic recovery segments, the saved mic file is the
/// primary alone and the later segments hold the rest of the meeting. These
/// tests pin the promise that Stop records that fact and that the journal
/// (the only inventory of those segments) outlives the saved transcript.
final class MicMergeFailureRetentionTests: XCTestCase {
    private var root: URL!
    private var immutableURLs: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicMergeFailureRetentionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for url in immutableURLs {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        }
        immutableURLs = []
        try? FileManager.default.removeItem(at: root)
    }

    private func makeAudio() -> Audio {
        Audio(paths: CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: scratch,
            logs: root.appendingPathComponent("logs", isDirectory: true)
        ))
    }

    private var scratch: URL { root.appendingPathComponent("tmp/recordings", isDirectory: true) }

    private func writeMonoWAV(named name: String, frames: Int, sampleRate: Double = 48_000) throws -> URL {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent(name)
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
        if frames > 0 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            let samples = try XCTUnwrap(buffer.floatChannelData)[0]
            for index in 0..<frames { samples[index] = 0.25 }
            try file.write(from: buffer)
        }
        file.close()
        return url
    }

    /// A merge writes `<primary>_merged.wav`. An immutable directory at that
    /// path can be neither removed nor written, so the merge throws while the
    /// source segments stay readable: the disk-trouble case the fallback is for.
    private func blockMergedOutput(for primary: URL) throws {
        let blocked = scratch.appendingPathComponent(
            primary.deletingPathExtension().lastPathComponent + "_merged.wav",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocked.path)
        immutableURLs.append(blocked)
    }

    // MARK: - Stop

    func testFailedMergeFallsBackToThePrimaryAndKeepsEverySegment() throws {
        let audio = makeAudio()
        let primary = try writeMonoWAV(named: "meeting_mic.wav", frames: 4_800)
        let recovery = try writeMonoWAV(named: "meeting_mic_recovery.wav", frames: 4_800)
        try blockMergedOutput(for: primary)

        let result = audio.finalizeMicRecordingResult(
            primaryURL: primary,
            segments: [MicRecordingSegment(url: primary), MicRecordingSegment(url: recovery, gapBeforeDuration: 0.5)]
        )

        XCTAssertEqual(result.url, primary)
        XCTAssertTrue(result.mergeFailed, "the caller must learn the saved file holds only part of the meeting")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path), "the unmerged segment is never deleted")
    }

    func testMergeThatOnlySkippedAnUnreadableSegmentIsNotAFailure() throws {
        let audio = makeAudio()
        let primary = try writeMonoWAV(named: "meeting_mic.wav", frames: 4_800)
        let missing = scratch.appendingPathComponent("never-written.wav")

        let result = audio.finalizeMicRecordingResult(
            primaryURL: primary,
            segments: [MicRecordingSegment(url: primary), MicRecordingSegment(url: missing)]
        )

        XCTAssertEqual(result.url?.lastPathComponent, "meeting_mic_merged.wav")
        XCTAssertFalse(result.mergeFailed, "the merged file holds every readable frame")
    }

    func testStopRecordsAFailedMergeInTheJournal() throws {
        let audio = makeAudio()
        let primary = try writeMonoWAV(named: "meeting_mic.wav", frames: 4_800)
        let recovery = try writeMonoWAV(named: "meeting_mic_recovery.wav", frames: 4_800)
        let segments = [MicRecordingSegment(url: primary), MicRecordingSegment(url: recovery, gapBeforeDuration: 0.5)]
        try blockMergedOutput(for: primary)
        let session = try audio.recordingJournal.begin(primaryMicURL: primary)
        audio.recordingJournal.recordSegments(segments, session: session)
        audio.retainStoppingJournalSession(session, generation: 7)

        let finalization = audio.finalizeStoppedMicRecordingResult(primaryURL: primary, segments: segments, generation: 7)
        audio.recordingJournal.flush()

        XCTAssertEqual(finalization.micURL, primary)
        let journalURL = scratch.appendingPathComponent("meeting_mic" + MeetingRecordingJournalStore.filenameSuffix)
        let journal = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalURL))
        XCTAssertEqual(journal.state, .finalized)
        XCTAssertEqual(journal.micMergeFailed, true)
        XCTAssertEqual(journal.finalMicFilename, "meeting_mic.wav")
    }

    func testStopLeavesTheJournalUnmarkedWhenTheMergeSucceeds() throws {
        let audio = makeAudio()
        let primary = try writeMonoWAV(named: "meeting_mic.wav", frames: 4_800)
        let recovery = try writeMonoWAV(named: "meeting_mic_recovery.wav", frames: 4_800)
        let segments = [MicRecordingSegment(url: primary), MicRecordingSegment(url: recovery, gapBeforeDuration: 0.5)]
        let session = try audio.recordingJournal.begin(primaryMicURL: primary)
        audio.recordingJournal.recordSegments(segments, session: session)
        audio.retainStoppingJournalSession(session, generation: 8)

        _ = audio.finalizeStoppedMicRecordingResult(primaryURL: primary, segments: segments, generation: 8)
        audio.recordingJournal.flush()

        let journalURL = scratch.appendingPathComponent("meeting_mic" + MeetingRecordingJournalStore.filenameSuffix)
        let journal = try XCTUnwrap(MeetingRecordingJournalStore.load(at: journalURL))
        XCTAssertNil(journal.micMergeFailed)
    }

    // MARK: - Durable handoff

    private func finalizedJournal(
        primary: URL,
        segments: [MicRecordingSegment],
        mergeFailed: Bool
    ) throws -> URL {
        let store = MeetingRecordingJournalStore(directory: scratch)
        let session = try store.begin(primaryMicURL: primary)
        store.recordSegments(segments, session: session)
        store.markFinalized(finalMicURL: primary, micMergeFailed: mergeFailed, session: session)
        store.flush()
        return scratch.appendingPathComponent(
            primary.deletingPathExtension().lastPathComponent + MeetingRecordingJournalStore.filenameSuffix
        )
    }

    func testJournalOutlivesATranscriptSavedFromAPartialMic() throws {
        let primary = try writeMonoWAV(named: "meeting_mic.wav", frames: 4_800)
        let recovery = try writeMonoWAV(named: "meeting_mic_recovery.wav", frames: 4_800)
        let journalURL = try finalizedJournal(
            primary: primary,
            segments: [MicRecordingSegment(url: primary), MicRecordingSegment(url: recovery, gapBeforeDuration: 0.5)],
            mergeFailed: true
        )

        let removed = MeetingRecordingJournalStore.removeJournal(
            micAudioURL: primary,
            systemAudioURL: nil,
            allowedRoots: [scratch]
        )

        XCTAssertFalse(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path), "it is the only inventory of the unmerged segment")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertTrue(MeetingRecordingJournalStore.hasRecordingJournal(
            micAudioURL: primary,
            systemAudioURL: nil,
            allowedRoots: [scratch]
        ))
    }

    func testJournalOfACompleteMergeIsRetiredAsBefore() throws {
        let primary = try writeMonoWAV(named: "meeting_mic.wav", frames: 4_800)
        let recovery = try writeMonoWAV(named: "meeting_mic_recovery.wav", frames: 4_800)
        let journalURL = try finalizedJournal(
            primary: primary,
            segments: [MicRecordingSegment(url: primary), MicRecordingSegment(url: recovery)],
            mergeFailed: false
        )

        XCTAssertTrue(MeetingRecordingJournalStore.removeJournal(
            micAudioURL: primary,
            systemAudioURL: nil,
            allowedRoots: [scratch]
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testJournalIsRetiredWhenTheUnmergedSegmentsHoldNoAudio() throws {
        let primary = try writeMonoWAV(named: "meeting_mic.wav", frames: 4_800)
        let headerOnly = try writeMonoWAV(named: "meeting_mic_recovery.wav", frames: 0)
        let gone = scratch.appendingPathComponent("meeting_mic_recovery_2.wav")
        let journalURL = try finalizedJournal(
            primary: primary,
            segments: [MicRecordingSegment(url: primary), MicRecordingSegment(url: headerOnly), MicRecordingSegment(url: gone)],
            mergeFailed: true
        )

        XCTAssertTrue(
            MeetingRecordingJournalStore.removeJournal(micAudioURL: primary, systemAudioURL: nil, allowedRoots: [scratch]),
            "a header-only or missing segment lost nothing, so nothing keeps the journal"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalURL.path))
    }

    func testDeletingTheMeetingStillSweepsTheRetainedSegments() throws {
        let primary = try writeMonoWAV(named: "meeting_mic.wav", frames: 4_800)
        let recovery = try writeMonoWAV(named: "meeting_mic_recovery.wav", frames: 4_800)
        let journalURL = try finalizedJournal(
            primary: primary,
            segments: [MicRecordingSegment(url: primary), MicRecordingSegment(url: recovery, gapBeforeDuration: 0.5)],
            mergeFailed: true
        )

        XCTAssertTrue(MeetingRecordingJournalStore.discardRecordingArtifacts(
            micAudioURL: primary,
            systemAudioURL: nil,
            allowedRoots: [scratch]
        ))

        for url in [primary, recovery, journalURL] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "an explicit discard owns the whole inventory")
        }
    }
}
