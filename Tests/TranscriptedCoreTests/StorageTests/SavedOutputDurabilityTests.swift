import XCTest
@testable import TranscriptedCore

/// After the pipeline saves a transcript and retains the audio, it deletes the
/// recording journal and the scratch audio, the only things that could rebuild
/// them. These tests pin that both outputs are flushed to the drive first, and
/// that a copy which could not be flushed does not count as archived (so its
/// scratch original is kept).
@available(macOS 14.0, *)
final class SavedOutputDurabilityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedOutputDurabilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Archive

    func testArchiveFlushesEachCopyAfterItIsWrittenThenTheFolderEntries() throws {
        let (micURL, systemURL, transcriptURL, archiveRoot) = try makeScratchAudio()
        let durability = RecordingDurability()

        let retained = try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: systemURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot,
            durability: durability
        )

        let events = durability.events
        XCTAssertEqual(
            events.map(\.label),
            [
                "file microphone.wav",
                "file system_audio.wav",
                "directory \(retained.directory.lastPathComponent)",
                "directory \(archiveRoot.lastPathComponent)",
            ],
            "copies first, then the folder entries that name them"
        )
        XCTAssertEqual(events.first?.bytesOnDisk, 3, "the mic copy was complete when it was flushed")
        XCTAssertEqual(events.dropFirst().first?.bytesOnDisk, 6, "the system copy was complete when it was flushed")
        XCTAssertNotNil(retained.micURL)
        XCTAssertNotNil(retained.systemURL)
    }

    func testCopyThatCouldNotBeFlushedIsReportedAsNotArchivedSoScratchIsKept() throws {
        let (micURL, systemURL, transcriptURL, archiveRoot) = try makeScratchAudio()
        let durability = RecordingDurability(failingFiles: ["microphone.wav"])

        let retained = try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: systemURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot,
            durability: durability
        )

        XCTAssertNil(retained.micURL, "an unflushed copy must not authorize deleting the scratch original")
        XCTAssertNotNil(retained.systemURL, "the other track is still archived")
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testArchiveThatCannotFlushAnythingFailsSoNothingIsDeleted() throws {
        let (micURL, systemURL, transcriptURL, archiveRoot) = try makeScratchAudio()
        let durability = RecordingDurability(failingFiles: ["microphone.wav", "system_audio.wav"])

        XCTAssertThrowsError(try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: systemURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot,
            durability: durability
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemURL.path))
    }

    func testVolumeThatHasNoFlushIsTreatedAsDone() throws {
        let (micURL, systemURL, transcriptURL, archiveRoot) = try makeScratchAudio()
        let durability = RecordingDurability(outcome: .unsupported)

        let retained = try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: systemURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot,
            durability: durability
        )

        XCTAssertNotNil(retained.micURL)
        XCTAssertNotNil(retained.systemURL)
    }

    func testFlushFailureOfTheFolderEntryDoesNotUndoACopyThatWasFlushed() throws {
        let (micURL, systemURL, transcriptURL, archiveRoot) = try makeScratchAudio()
        let durability = RecordingDurability(failDirectories: true)

        let retained = try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: systemURL,
            transcriptURL: transcriptURL,
            archiveRoot: archiveRoot,
            durability: durability
        )

        XCTAssertNotNil(retained.micURL)
        XCTAssertNotNil(retained.systemURL)
    }

    // MARK: - Transcript

    func testSavedTranscriptIsFlushedAfterItIsWritten() throws {
        let directory = root.appendingPathComponent("transcripts", isDirectory: true)
        let durability = RecordingDurability()

        let savedURL = SavedFileDurability.withOverride(durability) {
            TranscriptSaver.saveTranscript(
                makeResult(),
                transcriptId: UUID(),
                directory: directory,
                meetingTitle: "Durable Call",
                statsStore: NoopStatsStore(),
                recordingDate: Date(),
                transcriptionEngine: .parakeetLocal
            )
        }

        let url = try XCTUnwrap(savedURL)
        let events = durability.events
        XCTAssertEqual(events.map(\.label), ["file \(url.lastPathComponent)", "directory transcripts"])
        XCTAssertEqual(
            events.first?.bytesOnDisk,
            try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
            "the transcript was fully written before it was flushed"
        )
    }

    func testTranscriptStaysSavedWhenItCannotBeFlushed() throws {
        let directory = root.appendingPathComponent("transcripts", isDirectory: true)
        let durability = RecordingDurability(outcome: .failed)

        let savedURL = SavedFileDurability.withOverride(durability) {
            TranscriptSaver.saveTranscript(
                makeResult(),
                transcriptId: UUID(),
                directory: directory,
                statsStore: NoopStatsStore(),
                recordingDate: Date(),
                transcriptionEngine: .parakeetLocal
            )
        }

        let url = try XCTUnwrap(savedURL, "the file is written; a failed flush must not turn the save into a loss")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Durable words."))
    }

    // MARK: - The real barrier

    func testRealBarrierFlushesFilesAndDirectoriesAndReportsMissingPaths() throws {
        let file = root.appendingPathComponent("saved.md")
        try Data("saved".utf8).write(to: file)
        let barrier = DurableFileSync()

        XCTAssertTrue(barrier.syncFile(at: file).isSafeToRelyOn)
        XCTAssertTrue(barrier.syncDirectory(at: root).isSafeToRelyOn)
        XCTAssertEqual(barrier.syncFile(at: root.appendingPathComponent("missing.md")), .failed)
        XCTAssertEqual(DurableFileSync.outcome(forErrno: ENOTSUP), .unsupported)
        XCTAssertEqual(DurableFileSync.outcome(forErrno: EIO), .failed)
    }

    // MARK: - Fixtures

    private func makeScratchAudio() throws -> (mic: URL, system: URL, transcript: URL, archiveRoot: URL) {
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        let archiveRoot = root.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let micURL = scratch.appendingPathComponent("meeting_mic.wav")
        let systemURL = scratch.appendingPathComponent("meeting_system.wav")
        try Data("mic".utf8).write(to: micURL)
        try Data("system".utf8).write(to: systemURL)
        return (micURL, systemURL, root.appendingPathComponent("Call_2026-04-20_10-30-00.md"), archiveRoot)
    }

    private func makeResult() -> TranscriptionResult {
        TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Durable words."
                )
            ],
            duration: 2,
            processingTime: 0.5
        )
    }
}

/// Records every barrier call, with how many bytes the file held at that
/// moment, and fails the ones a test asks it to.
private final class RecordingDurability: FileDurability, @unchecked Sendable {
    struct Event {
        let label: String
        let bytesOnDisk: Int?
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private let failingFiles: Set<String>
    private let failDirectories: Bool
    private let outcome: FileSyncOutcome

    init(failingFiles: Set<String> = [], failDirectories: Bool = false, outcome: FileSyncOutcome = .synced) {
        self.failingFiles = failingFiles
        self.failDirectories = failDirectories
        self.outcome = outcome
    }

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func syncFile(at url: URL) -> FileSyncOutcome {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int
        lock.lock()
        recorded.append(Event(label: "file \(url.lastPathComponent)", bytesOnDisk: size))
        lock.unlock()
        return failingFiles.contains(url.lastPathComponent) ? .failed : outcome
    }

    func syncDirectory(at url: URL) -> FileSyncOutcome {
        lock.lock()
        recorded.append(Event(label: "directory \(url.lastPathComponent)", bytesOnDisk: nil))
        lock.unlock()
        return failDirectories ? .failed : outcome
    }
}

@available(macOS 14.0, *)
private final class NoopStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}
    func getTotalRecordingsCount() -> Int { 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }
    func recordingExists(transcriptPath: String) -> Bool { false }
}
