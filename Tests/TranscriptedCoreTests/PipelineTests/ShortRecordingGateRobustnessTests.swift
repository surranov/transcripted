import XCTest
import AVFoundation
@testable import TranscriptedCore

/// The live "too short" gate is the one place a recording is deleted without a
/// failed-queue row. These tests pin the promise that a real meeting never
/// reaches it, whatever the WAV header claims.
@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testDiscardPolicyOnlyAllowsFilesSmallEnoughToBeAHotkeyBump() {
        let limit = ShortRecordingDiscardPolicy.maximumDiscardableBytes
        XCTAssertTrue(ShortRecordingDiscardPolicy.mayDiscard(fileSizes: []))
        XCTAssertTrue(ShortRecordingDiscardPolicy.mayDiscard(fileSizes: [0, 44, limit]))
        XCTAssertFalse(ShortRecordingDiscardPolicy.mayDiscard(fileSizes: [limit + 1]))
        XCTAssertFalse(
            ShortRecordingDiscardPolicy.mayDiscard(fileSizes: [1_000, limit + 1]),
            "one large track is enough to keep the whole capture"
        )
        XCTAssertFalse(
            ShortRecordingDiscardPolicy.mayDiscard(fileSizes: [1_000, nil]),
            "a file whose size can't be read is never deleted"
        )
    }

    func testMeetingWithUnfinalizedWAVHeaderIsTranscribedNotDeletedAsTooShort() async throws {
        // A crashed or racing writer leaves the data chunk declared as 0 bytes,
        // so the file reads as ~0 s although the PCM payload is intact.
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "The whole meeting survived.")
        )
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let micURL = scratchDirectory.appendingPathComponent("unfinalized-mic.wav")
        try writeMonoWAV(to: micURL, duration: 3)
        try zeroDeclaredDataSize(of: micURL)
        XCTAssertEqual(try WAVHeaderRepair.probe(at: micURL).dataDeclaredSize, 0, "fixture must look unfinalized")

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            sessionLength: 3.5
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }
        XCTAssertNotEqual(manager.displayStatus, .discardedAccidentalStart)
        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("The whole meeting survived."))
    }

    func testLargeCaptureThatReadsAsShortIsQueuedForRetryInsteadOfDeleted() throws {
        // Header says 1 s, the file holds far more (a legal trailing chunk
        // stands in for audio the header doesn't admit to). Length can't be
        // trusted, so the gate must keep it.
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let micURL = scratchDirectory.appendingPathComponent("large-mic.wav")
        try writeMonoWAV(to: micURL, duration: 1.0)
        try appendTrailingChunk(to: micURL, byteCount: ShortRecordingDiscardPolicy.maximumDiscardableBytes + 1_024)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            sessionLength: 1.4
        )

        XCTAssertNotEqual(manager.displayStatus, .discardedAccidentalStart, "a large capture is never an accidental start")
        XCTAssertEqual(manager.lastFailureDiagnosticMessage, "Recording length could not be verified")
        let row = try XCTUnwrap(
            manager.failedTranscriptionManager.failedTranscriptions.first,
            "the audio must be owned by a retryable failed row"
        )
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertTrue(row.isRetryable)
        XCTAssertTrue(row.audioFilesExist(), "the audio must still be on disk")
        XCTAssertEqual(manager.activeCount, 0)
    }

    func testSmallCaptureThatReadsAsShortIsStillDiscardedAsAnAccidentalStart() throws {
        let manager = makeManager()
        let scratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        let micURL = scratchDirectory.appendingPathComponent("tap-mic.wav")
        try writeMonoWAV(to: micURL, duration: 1.0)
        try zeroDeclaredDataSize(of: micURL)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            sessionLength: 1.4
        )

        // Repair reveals the true 1 s length, which is still a tap.
        XCTAssertEqual(manager.displayStatus, .discardedAccidentalStart)
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
    }

    private func zeroDeclaredDataSize(of url: URL) throws {
        let info = try WAVHeaderRepair.probe(at: url)
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let headerOnlyRIFFSize = UInt32(info.dataSizeFieldOffset - 4)
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: headerOnlyRIFFSize.littleEndian) { Data($0) })
        try handle.seek(toOffset: UInt64(info.dataSizeFieldOffset))
        try handle.write(contentsOf: Data([0, 0, 0, 0]))
    }

    /// Appends a RIFF `LIST` chunk after the data chunk and fixes the RIFF
    /// size, the way a metadata-carrying WAV is laid out.
    private func appendTrailingChunk(to url: URL, byteCount: Int) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var chunk = Data("LIST".utf8)
        chunk.append(withUnsafeBytes(of: UInt32(byteCount).littleEndian) { Data($0) })
        chunk.append(Data(count: byteCount))
        try handle.write(contentsOf: chunk)
        let fileSize = try handle.offset()
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Data($0) })
    }
}
