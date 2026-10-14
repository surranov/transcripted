// DictationVersionTabsTests.swift
// Fork: an expanded Dictations card offers a tab per text the dictation went
// through, labeled with its model, and opens on the text that was saved.

import Foundation

func testDictationVersionTabs() {
    let at = Date(timeIntervalSince1970: 1_791_960_000)

    func version(_ stage: DictationTextVersion.Stage, _ model: String?, _ text: String) -> DictationTextVersion {
        DictationTextVersion(stage: stage, model: model, text: text, createdAt: at)
    }

    runSuite("The original and the model's version, each labeled, opening on the saved text") {
        let layout = DictationVersionTabs.layout(
            versions: [
                version(.recognized, "parakeet-tdt-v3", "ну давай созвонимся"),
                version(.refined, "gemma-4-e2b-it-q4_0", "Давай созвонимся."),
            ],
            savedText: "Давай созвонимся.\n"
        )
        assertEqual(layout?.tabs.map(\.title), ["Original · Parakeet V3", "Gemma 4 E2B"], "named by their models")
        assertEqual(layout?.tabs.map(\.text), ["ну давай созвонимся", "Давай созвонимся."], "each tab holds its text")
        assertEqual(layout?.savedTabID, 1, "the card opens on what was pasted")
    }

    runSuite("Nothing to choose between shows no tabs") {
        assertNil(DictationVersionTabs.layout(versions: [], savedText: "текст"), "an entry without versions")
        assertNil(
            DictationVersionTabs.layout(versions: [version(.recognized, "parakeet-tdt-v3", "текст")], savedText: "текст"),
            "a take the model didn't change: one text"
        )
        assertNil(DictationVersionTabs.layout(versions: [version(.recognized, "parakeet-tdt-v3", "текст")], savedText: "  "),
                  "an empty saved text adds no tab")
    }

    runSuite("Several runs: every text in order, a repeated model numbered, the latest match selected") {
        let layout = DictationVersionTabs.layout(
            versions: [
                version(.earlier, nil, "старый"),
                version(.recognized, "parakeet-tdt-v3", "раз"),
                version(.refined, "gemma-4-e2b-it-q4_0", "Раз."),
                version(.recognized, "breeze-asr-25", "раз два"),
                version(.refined, "gemma-4-e2b-it-q4_0", "Раз, два."),
            ],
            savedText: "Раз, два."
        )
        assertEqual(
            layout?.tabs.map(\.title),
            ["Earlier", "Original · Parakeet V3", "Gemma 4 E2B", "Original · Breeze", "Gemma 4 E2B 2"],
            "the text from before versions, both runs, the second answer numbered"
        )
        assertEqual(layout?.savedTabID, 4, "the latest run's answer is what was saved")
    }

    runSuite("A saved text edited by hand gets its own tab and opens on it") {
        let layout = DictationVersionTabs.layout(
            versions: [
                version(.recognized, "parakeet-tdt-v3", "раз"),
                version(.refined, "gemma-4-e2b-it-q4_0", "Раз."),
            ],
            savedText: "Раз, исправлено руками."
        )
        assertEqual(layout?.tabs.last?.title, DictationVersionTabs.savedTitle, "the edited text is its own tab")
        assertEqual(layout?.tabs.last?.text, "Раз, исправлено руками.", "with the saved text")
        assertEqual(layout?.savedTabID, 2, "and the card opens on it")
    }

    runSuite("A model the app no longer offers is labeled by its id") {
        assertEqual(
            DictationVersionTabs.title(for: version(.refined, "qwen-3-retired", "x")), "qwen-3-retired",
            "an unknown LLM shows its id"
        )
        assertEqual(
            DictationVersionTabs.title(for: version(.recognized, "old-asr", "x")), "Original · old-asr",
            "an unknown recognizer too"
        )
        assertEqual(DictationVersionTabs.title(for: version(.recognized, nil, "x")), "Original", "no model, no name")
    }
}
