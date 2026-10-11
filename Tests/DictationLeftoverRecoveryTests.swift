import Foundation

// Launch turns leftover dictation checkpoints into saved Dictations instead of
// deleting them. A checkpoint is retired only by a successful save; one that
// can't be read, transcribes to nothing, or fails to save stays for the next
// launch. One bad take never stops the rest.

private struct RecoveryProbe {
    var saved: [(UUID, String)] = []
}

private func recovery(_ id: UUID = UUID(), minutesAgo: Double) -> DictationStoppedAudioRecovery {
    DictationStoppedAudioRecovery(
        url: URL(fileURLWithPath: "/tmp/dictation_\(id.uuidString.lowercased()).wav"),
        sessionID: id,
        createdAt: Date().addingTimeInterval(-minutesAgo * 60)
    )
}

private enum FakeFailure: Error { case unreadable, busy }

func testDictationLeftoverRecovery() async {
    await runSuite("DictationLeftoverRecovery saves each recovered take with its refined text") {
        let first = recovery(minutesAgo: 10)
        let second = recovery(minutesAgo: 20)
        var probe = RecoveryProbe()
        let summary = await DictationLeftoverRecovery.run(DictationLeftoverRecovery.Steps(
            pending: { [first, second] },
            loadSamples: { _ in [0.1, 0.2] },
            transcribe: { _ in "  привет мир  " },
            clean: { $0.trimmingCharacters(in: .whitespaces) },
            refine: { "\($0)!" },
            save: { recovery, text in
                probe.saved.append((recovery.sessionID, text))
                return true
            }
        ))
        assertEqual(summary, DictationLeftoverRecovery.Summary(recovered: 2, noWords: 0, failed: 0), "both takes recovered")
        assertEqual(probe.saved.map(\.0), [first.sessionID, second.sessionID], "takes are saved in the order given")
        assertEqual(probe.saved.first?.1, "привет мир!", "the saved text is cleaned, then refined")
    }

    await runSuite("DictationLeftoverRecovery keeps takes it can't recover and goes on") {
        let unreadable = recovery(minutesAgo: 1)
        let silent = recovery(minutesAgo: 2)
        let busy = recovery(minutesAgo: 3)
        let unsaved = recovery(minutesAgo: 4)
        let good = recovery(minutesAgo: 5)
        var savedIDs: [UUID] = []
        let summary = await DictationLeftoverRecovery.run(DictationLeftoverRecovery.Steps(
            pending: { [unreadable, silent, busy, unsaved, good] },
            loadSamples: { url in
                if url == unreadable.url { throw FakeFailure.unreadable }
                return [0.5]
            },
            transcribe: { _ in "" },
            clean: { $0 },
            refine: { $0 },
            save: { _, _ in true }
        ))
        // `transcribe` above returns nothing for every take; run a second pass
        // where only some fail, to see the rest still saved.
        assertEqual(summary.noWords, 4, "takes that transcribe to nothing keep their WAV")
        assertEqual(summary.failed, 1, "an unreadable WAV counts as failed and stays")
        assertEqual(summary.recovered, 0, "nothing without words is saved")

        let mixed = await DictationLeftoverRecovery.run(DictationLeftoverRecovery.Steps(
            pending: { [busy, unsaved, good] },
            loadSamples: { _ in [0.5] },
            transcribe: { _ in "слова" },
            clean: { $0 },
            refine: { $0 },
            save: { recovery, _ in
                if recovery.sessionID == unsaved.sessionID { return false }
                savedIDs.append(recovery.sessionID)
                return true
            }
        ))
        assertEqual(mixed.failed, 1, "a failed save counts as failed")
        assertEqual(mixed.recovered, 2, "the takes around it are still saved")
        assertEqual(savedIDs, [busy.sessionID, good.sessionID], "only the takes that saved are reported saved")

        let throwing = await DictationLeftoverRecovery.run(DictationLeftoverRecovery.Steps(
            pending: { [busy, good] },
            loadSamples: { _ in [0.5] },
            transcribe: { _ in throw FakeFailure.busy },
            clean: { $0 },
            refine: { $0 },
            save: { _, _ in true }
        ))
        assertEqual(throwing.failed, 2, "a busy or failing model leaves every take for the next launch")
    }

    await runSuite("DictationLeftoverRecovery waits for a refiner that is still loading") {
        var calls = 0
        let refined = await DictationLeftoverRecovery.refineWhenReady("текст", attempts: 5, delay: .milliseconds(1)) { text in
            calls += 1
            return calls < 3 ? .unchanged(.notReady) : .refined(text + "!")
        }
        assertEqual(refined, "текст!", "the take gets the pass once the model is up")
        assertEqual(calls, 3, "asked again only while not ready")

        calls = 0
        let neverReady = await DictationLeftoverRecovery.refineWhenReady("текст", attempts: 4, delay: .milliseconds(1)) { _ in
            calls += 1
            return .unchanged(.notReady)
        }
        assertEqual(neverReady, "текст", "a model that never comes up leaves the recognized text")
        assertEqual(calls, 4, "and the wait is bounded")

        calls = 0
        let off = await DictationLeftoverRecovery.refineWhenReady("текст", attempts: 4, delay: .milliseconds(1)) { _ in
            calls += 1
            return .unchanged(.noPrompt)
        }
        assertEqual(off, "текст", "a pass turned off is final")
        assertEqual(calls, 1, "and isn't asked again")
    }

    runSuite("DictationLeftoverRecovery only takes checkpoints written before this launch") {
        let launchedAt = Date()
        let earlier = recovery(minutesAgo: 30)
        let thisRun = DictationStoppedAudioRecovery(
            url: URL(fileURLWithPath: "/tmp/dictation_now.wav"),
            sessionID: UUID(),
            createdAt: launchedAt.addingTimeInterval(5)
        )
        let older = recovery(minutesAgo: 90)
        let picked = DictationLeftoverRecovery.earlierRuns([thisRun, earlier, older], launchedAt: launchedAt)
        assertEqual(
            picked.map(\.sessionID),
            [older.sessionID, earlier.sessionID],
            "a take this run is still finishing is never touched; the rest go oldest first"
        )
    }
}
