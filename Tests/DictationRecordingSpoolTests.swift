import Foundation

// The recording spool keeps a take on disk while it records, in the stop
// checkpoint's own file and format, so a crash mid-take leaves a leftover that
// launch recovery reads like any other. Real files in a temp directory.

private func makeSpoolTestDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("DictationRecordingSpoolTests-\(UUID().uuidString)", isDirectory: true)
}

private func spoolTestSamples(_ count: Int, offset: Int = 0) -> [Float] {
    (0..<count).map { Float(sin(Double($0 + offset) / 7)) * 0.5 }
}

private func filesIn(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

func testDictationRecordingSpool() async {
    runSuite("DictationRecordingSpool writes the stop checkpoint's exact file, a piece at a time") {
        let directory = makeSpoolTestDirectory()
        let stopDirectory = makeSpoolTestDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: stopDirectory)
        }
        let sessionID = UUID()
        let first = spoolTestSamples(16_000)
        let second = spoolTestSamples(8_000, offset: 16_000)
        do {
            let spool = DictationRecordingSpool(sessionID: sessionID, directory: directory)
            try spool.append(first)
            try spool.append(second)
            let stop = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: first + second,
                sessionID: sessionID,
                directory: stopDirectory
            )
            assertEqual(
                try Data(contentsOf: spool.recovery.url),
                try Data(contentsOf: stop!.url),
                "byte for byte what the stop would write for the same audio"
            )
            assertEqual(
                spool.recovery.url.lastPathComponent,
                stop!.url.lastPathComponent,
                "the same file name, so the stop's checkpoint replaces the spool's"
            )
        } catch {
            assertTrue(false, "spool write failed: \(error)")
        }
    }

    runSuite("DictationRecordingSpool leaves a take a crash cut short to launch recovery") {
        let directory = makeSpoolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSinceNow: -60)
        do {
            // The app dies mid-take: no end(), no stop checkpoint.
            let spool = DictationRecordingSpool(sessionID: sessionID, createdAt: startedAt, directory: directory)
            try spool.append(spoolTestSamples(32_000))
            try spool.append(spoolTestSamples(16_000))
            // ...and mid-way through the next append: its audio landed, its
            // header update didn't.
            let handle = try FileHandle(forWritingTo: spool.recovery.url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(repeating: 0x11, count: 3_000))
            try handle.close()

            let pending = DictationStoppedAudioRecoveryStore.pendingRecoveries(limit: .max, directory: directory)
            assertEqual(pending.map(\.sessionID), [sessionID], "the spool is a leftover checkpoint")
            assertEqual(
                pending.first.map { Int($0.createdAt.timeIntervalSince1970) },
                Int(startedAt.timeIntervalSince1970),
                "dated when the take started"
            )
            assertEqual(
                DictationLeftoverRecovery.earlierRuns(pending, launchedAt: Date()).count,
                1,
                "the next launch picks it up"
            )
            let samples = try DictationRetranscription.loadSamples16k(from: spool.recovery.url)
            assertTrue(
                abs(samples.count - 48_000) <= 16,
                "every append before the cut reads back (\(samples.count) of 48000)"
            )
        } catch {
            assertTrue(false, "spool write failed: \(error)")
        }
    }

    runSuite("DictationRecordingSpool writes nothing until there is audio") {
        let directory = makeSpoolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = DictationRecordingSpool(sessionID: UUID(), directory: directory)
        try? spool.append([])
        spool.end(keepingAudio: true)
        assertEqual(filesIn(directory), [], "a take that never got audio leaves no files")
    }

    runSuite("DictationRecordingSpool never writes after end") {
        let directory = makeSpoolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID()
        do {
            let spool = DictationRecordingSpool(sessionID: sessionID, directory: directory)
            try spool.append(spoolTestSamples(4_000))
            spool.end(keepingAudio: true)
            // Stop writes its checkpoint over the spool's file...
            let stop = try DictationStoppedAudioRecoveryStore.persist(
                samples16k: spoolTestSamples(20_000),
                sessionID: sessionID,
                directory: directory
            )
            let stopBytes = try Data(contentsOf: stop!.url)
            // ...and a late feed or a stray discard can't touch it.
            try spool.append(spoolTestSamples(4_000))
            spool.end(keepingAudio: false)
            assertEqual(try Data(contentsOf: stop!.url), stopBytes, "the stop's checkpoint is left exactly as written")
            assertEqual(filesIn(directory).count, 2, "its WAV and JSON both stay")

            // A take that ended before any audio can't create the file later.
            let silentDirectory = makeSpoolTestDirectory()
            defer { try? FileManager.default.removeItem(at: silentDirectory) }
            let silent = DictationRecordingSpool(sessionID: UUID(), directory: silentDirectory)
            silent.end(keepingAudio: true)
            try silent.append(spoolTestSamples(4_000))
            assertEqual(filesIn(silentDirectory), [], "an append after end creates nothing")
        } catch {
            assertTrue(false, "spool write failed: \(error)")
        }
    }

    runSuite("DictationRecordingSpool deletes its files on an explicit discard, keeps them otherwise") {
        let directory = makeSpoolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let discarded = DictationRecordingSpool(sessionID: UUID(), directory: directory)
            try discarded.append(spoolTestSamples(4_000))
            assertEqual(filesIn(directory).count, 2, "WAV and JSON while recording")
            discarded.end(keepingAudio: false)
            assertEqual(filesIn(directory), [], "a discarded take leaves nothing")

            let kept = DictationRecordingSpool(sessionID: UUID(), directory: directory)
            try kept.append(spoolTestSamples(4_000))
            kept.end(keepingAudio: true)
            kept.end(keepingAudio: false)
            assertEqual(filesIn(directory).count, 2, "only the first end decides")
        } catch {
            assertTrue(false, "spool write failed: \(error)")
        }
    }

    runSuite("DictationRecordingSpool stops for good after a write failure") {
        let blocker = makeSpoolTestDirectory()
        defer { try? FileManager.default.removeItem(at: blocker) }
        // A plain file where the checkpoint directory should be.
        FileManager.default.createFile(atPath: blocker.path, contents: Data([1]))
        let spool = DictationRecordingSpool(sessionID: UUID(), directory: blocker)
        var threw = false
        do { try spool.append(spoolTestSamples(100)) } catch { threw = true }
        assertTrue(threw, "the first failure is reported")
        var threwAgain = false
        do { try spool.append(spoolTestSamples(100)) } catch { threwAgain = true }
        assertTrue(!threwAgain, "then the spool is off, without failing every few seconds")
    }

    await runSuite("DictationRecordingSpoolPump feeds the spool until cancelled, and stops at a failure") {
        let directory = makeSpoolTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spool = DictationRecordingSpool(sessionID: UUID(), directory: directory)
        let pump = Task.detached {
            await DictationRecordingSpoolPump.run(
                spool,
                interval: .milliseconds(5),
                takeSamples: { spoolTestSamples(160) },
                reportFailure: { _ in }
            )
        }
        var waited = 0
        while spool.spooledByteCount < 320 * 3, waited < 400 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        pump.cancel()
        await pump.value
        assertTrue(spool.spooledByteCount >= 320 * 3, "the feed reaches the disk on each tick")

        let blocker = makeSpoolTestDirectory()
        defer { try? FileManager.default.removeItem(at: blocker) }
        FileManager.default.createFile(atPath: blocker.path, contents: Data([1]))
        let failing = DictationRecordingSpool(sessionID: UUID(), directory: blocker)
        let failures = FailureCounter()
        await DictationRecordingSpoolPump.run(
            failing,
            interval: .milliseconds(1),
            takeSamples: { spoolTestSamples(16) },
            reportFailure: { _ in failures.increment() }
        )
        assertEqual(failures.count, 1, "a failure is reported once and ends the loop")
    }
}

private final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
