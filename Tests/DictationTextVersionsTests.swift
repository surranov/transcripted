// DictationTextVersionsTests.swift
// Fork: a saved dictation keeps what recognition heard and what each model
// made of it, next to its day file, without ever risking the dictation itself.

import Foundation

func testDictationTextVersions() {
    let fileManager = FileManager.default
    let at = Date(timeIntervalSince1970: 1_791_960_000)

    func makeFolder() -> URL {
        let folder = fileManager.temporaryDirectory
            .appendingPathComponent("DictationTextVersionsTests-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func version(_ stage: DictationTextVersion.Stage, _ model: String?, _ text: String) -> DictationTextVersion {
        DictationTextVersion(stage: stage, model: model, text: text, createdAt: at)
    }

    runSuite("A finished take keeps the recognized text, and the model's answer only when it was accepted") {
        let refined = DictationTextVersion.take(
            recognized: "ну короче давай созвонимся",
            recognitionModel: "parakeet-tdt-v3",
            refinement: .refined("Давай созвонимся.", model: .gemma4E4B),
            at: at
        )
        assertEqual(refined, [
            version(.recognized, "parakeet-tdt-v3", "ну короче давай созвонимся"),
            version(.refined, "gemma-4-e4b-it-qat-q4_0", "Давай созвонимся."),
        ], "both texts, each with its model")

        for skip in [DictationTextRefinementSkip.noPrompt, .notReady, .failed, .rejected, .cancelled] {
            let kept = DictationTextVersion.take(
                recognized: "текст", recognitionModel: "breeze-asr-25", refinement: .unchanged(skip), at: at
            )
            assertEqual(kept, [version(.recognized, "breeze-asr-25", "текст")], "\(skip.rawValue) leaves only what was heard")
        }
    }

    runSuite("Versions read back in the order they were made; a repeat isn't added again") {
        let folder = makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        let entryID = "dictation-20261014-101500-000-0b7c8f3e-7a3c-4d0e-9a51-2f0c6d1a9e11"
        let first = [version(.recognized, "parakeet-tdt-v3", "раз"), version(.refined, "gemma-4-e2b-it-q4_0", "Раз.")]
        do {
            try DictationTextVersionStore.append(first, entryID: entryID, in: folder)
            try DictationTextVersionStore.append(
                [version(.recognized, "parakeet-tdt-v3", "раз"), version(.refined, "gemma-4-e4b-it-qat-q4_0", "Раз!")],
                entryID: entryID,
                in: folder
            )
        } catch {
            assertTrue(false, "appending versions should work: \(error)")
        }
        let loaded = DictationTextVersionStore.load(entryID: entryID, in: folder)
        assertEqual(loaded.map(\.text), ["раз", "Раз.", "Раз!"], "the same recognized text isn't kept twice")
        assertEqual(loaded.last?.model, "gemma-4-e4b-it-qat-q4_0", "the new model's answer is added")
        let url = folder.appendingPathComponent("versions/\(entryID).json")
        assertTrue(fileManager.fileExists(atPath: url.path), "the file sits in versions/ under the entry id")
        let permissions = (try? fileManager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        assertEqual(permissions, 0o600, "transcript text stays readable by the owner only")
    }

    runSuite("Past the cap the oldest versions go first") {
        let folder = makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        let entryID = "dictation-cap"
        for index in 0..<(DictationTextVersionStore.maximumVersions + 3) {
            try? DictationTextVersionStore.append([version(.refined, "m", "text \(index)")], entryID: entryID, in: folder)
        }
        let loaded = DictationTextVersionStore.load(entryID: entryID, in: folder)
        assertEqual(loaded.count, DictationTextVersionStore.maximumVersions, "the history is bounded")
        assertEqual(loaded.first?.text, "text 3", "the three oldest were dropped")
        assertEqual(loaded.last?.text, "text \(DictationTextVersionStore.maximumVersions + 2)", "the newest is kept")
    }

    runSuite("An entry id that isn't a plain file name never becomes a path") {
        let folder = makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        for unsafe in ["../escape", "a/b", "", "dictation x", "dictation-ä", String(repeating: "a", count: 201)] {
            assertNil(DictationTextVersionStore.fileURL(entryID: unsafe, in: folder), "\(unsafe.prefix(12)) has no file")
            var threw = false
            do {
                try DictationTextVersionStore.append([version(.recognized, nil, "x")], entryID: unsafe, in: folder)
            } catch {
                threw = true
            }
            assertTrue(threw, "writing under an unsafe id is refused")
            assertEqual(DictationTextVersionStore.load(entryID: unsafe, in: folder), [], "and reads as no versions")
        }
        let escaped = folder.deletingLastPathComponent().appendingPathComponent("escape.json")
        assertFalse(fileManager.fileExists(atPath: escaped.path), "nothing was written outside versions/")
    }

    runSuite("A missing or unreadable versions file means no versions, and a failed write doesn't fail the save") {
        let folder = makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        assertEqual(DictationTextVersionStore.load(entryID: "dictation-none", in: folder), [], "no file, no versions")

        let corrupt = folder.appendingPathComponent("versions/dictation-corrupt.json")
        try? fileManager.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data("{ not json".utf8).write(to: corrupt)
        assertEqual(DictationTextVersionStore.load(entryID: "dictation-corrupt", in: folder), [], "a broken file reads as none")

        let noID = SavedDictationTranscript(url: folder.appendingPathComponent("Dictations_2026-10-14.md"), title: "t")
        assertFalse(DictationTextVersionStore.record([version(.recognized, nil, "x")], for: noID),
                    "a save without an entry id reports no versions instead of throwing")

        // A plain file where the versions folder would go: the write fails.
        let blocked = folder.appendingPathComponent("blocked", isDirectory: true)
        try? fileManager.createDirectory(at: blocked, withIntermediateDirectories: true)
        try? Data("not a folder".utf8).write(to: blocked.appendingPathComponent("versions"))
        let saved = SavedDictationTranscript(
            url: blocked.appendingPathComponent("Dictations_2026-10-14.md"), title: "t", entryID: "dictation-blocked"
        )
        assertFalse(DictationTextVersionStore.record([version(.recognized, nil, "x")], for: saved),
                    "an unwritable versions folder is reported, not thrown")
    }

    runSuite("Transcribe again on an older entry keeps the text it replaces as Earlier, once") {
        let folder = makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        let entryID = "dictation-older"
        let earlier = version(.earlier, nil, "старый текст")
        let firstRun = [version(.recognized, "parakeet-tdt-v3", "новый"), version(.refined, "gemma-4-e2b-it-q4_0", "Новый.")]
        DictationTextVersionStore.recordRetranscription(firstRun, replacing: earlier, entryID: entryID, in: folder)
        let secondRun = [version(.recognized, "breeze-asr-25", "новый текст")]
        DictationTextVersionStore.recordRetranscription(
            secondRun, replacing: version(.earlier, nil, "Новый."), entryID: entryID, in: folder
        )
        let loaded = DictationTextVersionStore.load(entryID: entryID, in: folder)
        assertEqual(loaded.map(\.stage), [.earlier, .recognized, .refined, .recognized],
                    "the pre-versions text is kept first, and only for the first run")
        assertEqual(loaded.first?.text, "старый текст", "the replaced text is the one the entry had")

        let fresh = "dictation-fresh"
        DictationTextVersionStore.recordRetranscription(
            firstRun, replacing: version(.earlier, nil, "  "), entryID: fresh, in: folder
        )
        assertEqual(DictationTextVersionStore.load(entryID: fresh, in: folder).map(\.stage), [.recognized, .refined],
                    "an empty text isn't kept as a version")
    }

    runSuite("Deleting an entry's versions leaves the others alone") {
        let folder = makeFolder()
        defer { try? fileManager.removeItem(at: folder) }
        try? DictationTextVersionStore.append([version(.recognized, nil, "a")], entryID: "dictation-a", in: folder)
        try? DictationTextVersionStore.append([version(.recognized, nil, "b")], entryID: "dictation-b", in: folder)
        let entry = SavedDictationEntry(
            url: folder.appendingPathComponent("Dictations_2026-10-14.md"),
            entryID: "dictation-a",
            title: "a",
            text: "a",
            createdAt: at,
            delivery: .pasted,
            sourceAppName: "Notes",
            sourceAppBundleID: nil
        )
        assertEqual(DictationTextVersionStore.load(for: entry).map(\.text), ["a"], "an entry finds its versions by its day file's folder")
        DictationTextVersionStore.delete(for: entry)
        assertEqual(DictationTextVersionStore.load(entryID: "dictation-a", in: folder), [], "the deleted entry's versions are gone")
        assertEqual(DictationTextVersionStore.load(entryID: "dictation-b", in: folder).map(\.text), ["b"], "another entry's stay")
    }
}
