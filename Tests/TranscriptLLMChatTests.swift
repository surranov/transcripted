import Foundation

// The transcript LLM request: the whole user prompt as the system message
// (first, so the helper's prompt cache keeps it), the transcript between the
// benchmark's tags, near-deterministic sampling. And its answer: only a
// cleanly finished answer may stand in for the transcript.

private func decodedBody(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

private func answerData(content: Any?, finish: String?) -> Data {
    var message: [String: Any] = ["role": "assistant"]
    if let content { message["content"] = content }
    var choice: [String: Any] = ["index": 0, "message": message]
    if let finish { choice["finish_reason"] = finish }
    return (try? JSONSerialization.data(withJSONObject: ["choices": [choice]])) ?? Data()
}

func testTranscriptLLMChat() {
    runSuite("TranscriptLLMChat sends the prompt first and the transcript between the tags") {
        let data = (try? TranscriptLLMChat.requestBody(
            systemPrompt: "Fix it.",
            transcript: "привет мир",
            maxTokens: 140
        )) ?? Data()
        let body = decodedBody(data)
        let messages = body["messages"] as? [[String: String]] ?? []
        assertEqual(messages.count, 2, "one system and one user message")
        assertEqual(messages.first?["role"], "system", "the prompt is the system message")
        assertEqual(messages.first?["content"], "Fix it.", "the prompt goes in unchanged")
        assertEqual(messages.last?["role"], "user", "the transcript is the user message")
        assertEqual(
            messages.last?["content"],
            "<TRANSCRIPTION-START>\nпривет мир\n<TRANSCRIPTION-END>",
            "the transcript sits between the tags the prompt refers to"
        )
        assertEqual(body["cache_prompt"] as? Bool, true, "the helper keeps the prompt cached between dictations")
        assertEqual(body["max_tokens"] as? Int, 140, "the token ceiling is passed through")
        assertEqual(body["stream"] as? Bool, false, "one answer, not a stream")
        assertTrue((body["temperature"] as? Double ?? 1) <= 0.3, "cleanup sampling stays near-deterministic")
    }

    runSuite("TranscriptLLMChat leaves the answer room proportional to the transcript") {
        assertEqual(TranscriptLLMChat.maxTokens(transcript: ""), 128, "an empty transcript still gets headroom")
        assertEqual(TranscriptLLMChat.maxTokens(transcript: "one two three"), 3 * 4 + 128, "about four tokens per word")
    }

    runSuite("TranscriptLLMChat accepts only an answer that finished on its own") {
        assertEqual(
            TranscriptLLMChat.answer(from: answerData(content: "Привет, мир.", finish: "stop")),
            .text("Привет, мир."),
            "a stopped answer is text"
        )
        assertEqual(
            TranscriptLLMChat.answer(from: answerData(content: "Привет, м", finish: "length")),
            .truncated,
            "an answer cut off at the token limit must not replace the transcript"
        )
        assertEqual(
            TranscriptLLMChat.answer(from: answerData(content: nil, finish: "stop")),
            .malformed,
            "no content is malformed"
        )
        assertEqual(TranscriptLLMChat.answer(from: Data("not json".utf8)), .malformed, "garbage is malformed")
        assertEqual(
            TranscriptLLMChat.answer(from: answerData(content: "ok", finish: nil)),
            .text("ok"),
            "a missing finish reason is read as finished"
        )
    }
}
