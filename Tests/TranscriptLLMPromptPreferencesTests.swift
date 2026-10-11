import Foundation

// The transcript LLM prompts (dictation and meetings): a default until the
// user saves one, an empty saved prompt turns that pass off, and nothing
// longer than the model can read is ever saved.

private func freshDefaults() -> UserDefaults {
    let name = "TranscriptLLMPromptPreferencesTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

func testTranscriptLLMPromptPreferences() {
    runSuite("TranscriptLLMPromptPreference starts with each pass's default prompt") {
        let defaults = freshDefaults()
        for preference in [TranscriptLLMPromptPreference.dictation, .meeting] {
            assertEqual(preference.prompt(userDefaults: defaults), preference.defaultPrompt, "\(preference.key): nothing saved reads as the default")
            assertTrue(preference.defaultPrompt.contains("<TRANSCRIPTION-START>"), "\(preference.key): the default names the tags")
        }
        assertTrue(
            TranscriptLLMPromptPreference.dictation.key != TranscriptLLMPromptPreference.meeting.key,
            "the two prompts are saved separately"
        )
    }

    runSuite("TranscriptLLMPromptPreference keeps a saved empty prompt empty") {
        let defaults = freshDefaults()
        let preference = TranscriptLLMPromptPreference.meeting
        assertTrue(preference.setPrompt("", userDefaults: defaults), "clearing the prompt is a change")
        assertEqual(preference.prompt(userDefaults: defaults), "", "empty stays empty: the pass is off")
        assertFalse(preference.setPrompt("", userDefaults: defaults), "saving the same value is no change")
        assertEqual(
            TranscriptLLMPromptPreference.dictation.prompt(userDefaults: defaults),
            TranscriptLLMPromptPreference.dictation.defaultPrompt,
            "turning the meeting pass off leaves the dictation prompt alone"
        )
    }

    runSuite("TranscriptLLMPromptPreference caps the prompt at the model's budget") {
        let defaults = freshDefaults()
        let limit = TranscriptLLMPromptPreference.maxCharacters
        TranscriptLLMPromptPreference.dictation.setPrompt(String(repeating: "я", count: limit + 500), userDefaults: defaults)
        assertEqual(
            TranscriptLLMPromptPreference.dictation.prompt(userDefaults: defaults).count,
            limit,
            "a pasted prompt is cut at the cap"
        )
        assertEqual(TranscriptLLMPromptPreference.clamped("short"), "short", "a short prompt is untouched")
        assertEqual(limit, 30_000, "the cap sized against the 16k-token context")
    }
}
