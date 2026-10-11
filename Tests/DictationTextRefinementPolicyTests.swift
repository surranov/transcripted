import Foundation

// A refiner's answer replaces the transcript only when it still looks like
// the dictation: not empty, not a long reply to it, not most of it dropped.
// Anything else pastes the original, so the pass can never cost the take.

func testDictationTextRefinementPolicy() {
    let original = "Окей, посмотри, еще Нексус Нпм инсталл не работает, и проверь логи в графане, пожалуйста."

    runSuite("DictationTextRefinementPolicy accepts a corrected dictation") {
        let answer = "Окей, посмотри, ещё Nexus npm install не работает, и проверь логи в Grafana, пожалуйста."
        assertEqual(
            DictationTextRefinementPolicy.accepted(original: original, answer: answer),
            answer,
            "a same-length correction replaces the transcript"
        )
    }

    runSuite("DictationTextRefinementPolicy strips tags the model echoes back") {
        let answer = "<TRANSCRIPTION-START>\nПривет, мир.\n<TRANSCRIPTION-END>"
        assertEqual(
            DictationTextRefinementPolicy.accepted(original: "привет мир", answer: answer),
            "Привет, мир.",
            "echoed tags and their newlines go"
        )
    }

    runSuite("DictationTextRefinementPolicy rejects answers that aren't the dictation") {
        assertNil(DictationTextRefinementPolicy.accepted(original: original, answer: "   \n"), "an empty answer keeps the original")
        let reply = String(repeating: "Вот функция, которую вы просили. ", count: 10)
        assertNil(
            DictationTextRefinementPolicy.accepted(original: original, answer: reply),
            "a reply far longer than the dictation keeps the original"
        )
        assertNil(
            DictationTextRefinementPolicy.accepted(original: original, answer: "Окей."),
            "an answer that dropped most of a long dictation keeps the original"
        )
    }

    runSuite("DictationTextRefinementPolicy lets short dictations change shape") {
        assertEqual(DictationTextRefinementPolicy.accepted(original: "ок", answer: "OK."), "OK.", "short text has no lower bound")
        assertEqual(
            DictationTextRefinementPolicy.accepted(original: "дейли", answer: "Daily standup."),
            "Daily standup.",
            "short text may grow by the added-character allowance"
        )
    }

    runSuite("DictationTextRefinement pastes the original on every skip") {
        assertEqual(DictationTextRefinement.refined("B").text(original: "A"), "B", "a refined answer is delivered")
        for skip in [DictationTextRefinementSkip.noPrompt, .notReady, .failed, .rejected, .cancelled] {
            assertEqual(DictationTextRefinement.unchanged(skip).text(original: "A"), "A", "\(skip.rawValue) keeps the transcript")
        }
    }
}
