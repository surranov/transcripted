import Foundation

// Which model each transcript LLM pass runs: dictation on the faster model
// and meetings on the better one until the user picks, each pass saved on
// its own, and a model only counts as deletable once no pass runs it.

private func freshDefaults() -> UserDefaults {
    let name = "TranscriptLLMModelPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func testTranscriptLLMModelPreferences() {
    runSuite("TranscriptLLMModelPreference starts dictation on E2B and meetings on E4B") {
        let defaults = freshDefaults()
        assertEqual(TranscriptLLMModelPreference.dictation.choice(userDefaults: defaults), .gemma4E2B, "dictation: the faster model")
        assertEqual(TranscriptLLMModelPreference.meeting.choice(userDefaults: defaults), .gemma4E4B, "meetings: the better model")
    }

    runSuite("TranscriptLLMModelPreference saves each pass on its own") {
        let defaults = freshDefaults()
        assertTrue(
            TranscriptLLMModelPreference.dictation.setChoice(.gemma4E4B, userDefaults: defaults),
            "picking another model is a change"
        )
        assertEqual(TranscriptLLMModelPreference.dictation.choice(userDefaults: defaults), .gemma4E4B, "the pick is kept")
        assertEqual(TranscriptLLMModelPreference.meeting.choice(userDefaults: defaults), .gemma4E4B, "meetings keep their own model")
        assertFalse(
            TranscriptLLMModelPreference.dictation.setChoice(.gemma4E4B, userDefaults: defaults),
            "picking the same model again is no change"
        )
        assertTrue(
            TranscriptLLMModelPreference.dictation.key != TranscriptLLMModelPreference.meeting.key,
            "the two passes are saved separately"
        )
        assertTrue(
            !TranscriptLLMModelPreference.dictation.key.isEmpty
                && TranscriptLLMModelPreference.dictation.key != TranscriptLLMPromptPreference.dictation.key,
            "a model choice never overwrites a prompt"
        )
    }

    runSuite("TranscriptLLMModelPreference reads a model the app no longer offers as the default") {
        let defaults = freshDefaults()
        defaults.set("gemma-3-retired", forKey: TranscriptLLMModelPreference.meeting.key)
        assertEqual(TranscriptLLMModelPreference.meeting.choice(userDefaults: defaults), .gemma4E4B, "falls back to the pass's default")
    }

    runSuite("TranscriptLLMModelPreference counts a model in use while any pass runs it") {
        let defaults = freshDefaults()
        assertEqual(
            TranscriptLLMModelPreference.modelsInUse(userDefaults: defaults),
            [.gemma4E2B, .gemma4E4B],
            "by default each pass runs its own model"
        )
        TranscriptLLMModelPreference.dictation.setChoice(.gemma4E4B, userDefaults: defaults)
        assertEqual(
            TranscriptLLMModelPreference.modelsInUse(userDefaults: defaults),
            [.gemma4E4B],
            "dictation leaving E2B for meetings' model leaves E2B unused"
        )
        TranscriptLLMModelPreference.meeting.setChoice(.gemma4E2B, userDefaults: defaults)
        assertEqual(
            TranscriptLLMModelPreference.modelsInUse(userDefaults: defaults),
            [.gemma4E2B, .gemma4E4B],
            "a model one pass left stays in use while the other picks it"
        )
    }

    runSuite("TranscriptLLMModelChoice names one model folder per choice") {
        let folders = TranscriptLLMModelChoice.allCases.map(\.rawValue)
        assertEqual(Set(folders).count, folders.count, "no two choices share a folder")
        assertTrue(folders.allSatisfy { !$0.contains("/") && !$0.isEmpty }, "each is a single folder name")
    }

    runSuite("TranscriptLLMPass pairs each pass with its own prompt and model") {
        assertEqual(TranscriptLLMPass.dictation.prompt.key, TranscriptLLMPromptPreference.dictation.key, "dictation prompt")
        assertEqual(TranscriptLLMPass.meeting.prompt.key, TranscriptLLMPromptPreference.meeting.key, "meeting prompt")
        assertEqual(TranscriptLLMPass.dictation.model.key, TranscriptLLMModelPreference.dictation.key, "dictation model")
        assertEqual(TranscriptLLMPass.meeting.model.key, TranscriptLLMModelPreference.meeting.key, "meeting model")
    }
}
