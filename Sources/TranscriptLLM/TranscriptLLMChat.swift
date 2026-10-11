import Foundation

/// The wire format of one transcript request to the helper's OpenAI-compatible
/// `/v1/chat/completions`, and of its answer. Foundation-only so the fast tests
/// compile it.
///
/// The transcript goes in the user message between the
/// `<TRANSCRIPTION-START>`/`<TRANSCRIPTION-END>` tags, the layout the owner's
/// prompt and the 2026-10-10 benchmark used. The system prompt is the whole
/// user prompt and comes first, so llama-server's prompt cache keeps it between
/// requests and only the transcript is read each time.
enum TranscriptLLMChat {
    /// Sampling from the benchmark: near-deterministic, a cleanup isn't creative.
    static let temperature = 0.2
    static let topP = 0.9
    static let topK = 40

    static func userMessage(transcript: String) -> String {
        "\(DictationTextRefinementPolicy.transcriptOpenTag)\n\(transcript)\n\(DictationTextRefinementPolicy.transcriptCloseTag)"
    }

    /// Room for the answer: about four tokens per word plus headroom, as in the
    /// benchmark, which never hit it. An answer that does hit it is cut off
    /// mid-text and gets rejected (see `Answer.truncated`), so this is a
    /// ceiling against a looping model, not a budget the answer must fit.
    static func maxTokens(transcript: String) -> Int {
        let words = transcript.split(whereSeparator: \.isWhitespace).count
        return words * 4 + 128
    }

    static func requestBody(systemPrompt: String, transcript: String, maxTokens: Int, slot: Int? = nil) throws -> Data {
        var body: [String: Any] = [
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage(transcript: transcript)],
            ],
            "temperature": temperature,
            "top_p": topP,
            "top_k": topK,
            "max_tokens": maxTokens,
            "cache_prompt": true,
            "stream": false,
        ]
        // llama-server's slot pin: each caller keeps its own prompt cache.
        if let slot { body["id_slot"] = slot }
        return try JSONSerialization.data(withJSONObject: body)
    }

    enum Answer: Equatable, Sendable {
        case text(String)
        /// The model stopped at `max_tokens` or the context end: the text is
        /// cut off and must not replace the transcript.
        case truncated
        case malformed
    }

    static func answer(from data: Data) -> Answer {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else { return .malformed }
        if let finish = first["finish_reason"] as? String, finish != "stop" { return .truncated }
        guard let content = message["content"] as? String else { return .malformed }
        return .text(content)
    }
}
