import Foundation

/// Which job a `LlamaServerProcessHost` helper does.
///
/// Writing's autocomplete is the original job and keeps its flags unchanged.
/// The fork's transcript LLM (`Sources/TranscriptLLM/`) runs a second helper
/// of its own for chat completions over a finished transcript, so the two
/// never share a slot or a prompt cache: the `-np 1` note on
/// `LlamaServerProcessHost.launchConfiguration` asks any second consumer for
/// its own helper rather than a bigger `-np`.
enum LlamaLaunchProfile: Equatable, Sendable {
    case writingAutocomplete
    /// `/v1/chat/completions` through the model's own Jinja chat template,
    /// with thinking off (Gemma 4 otherwise spends its whole budget on
    /// reasoning and returns empty content). `contextTokens` bounds one
    /// slot's system prompt plus transcript plus answer; each of `slots`
    /// gets that much, so callers that pin `id_slot` keep their own prompt
    /// cache and never queue behind each other.
    case chat(contextTokens: Int, slots: Int, diagnosticsLabel: String)

    /// Tags this helper's lines in the shared Writing diagnostics log. Nil for
    /// Writing, whose lines stay exactly as they were.
    var diagnosticsLabel: String? {
        switch self {
        case .writingAutocomplete: nil
        case let .chat(_, _, label): label
        }
    }

    /// Flags for the chat profile. `--swa-full` keeps every layer's cache
    /// whole so the next request reuses the cached system prompt instead of
    /// re-reading it. `-c` is the total the server splits evenly across
    /// `-np` slots. Idle CPU threads asleep and no web UI, as for Writing.
    static func chatArguments(model: String, port: Int, contextTokens: Int, slots: Int) -> [String] {
        [
            "-m", model,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-c", String(contextTokens * max(1, slots)),
            "-np", String(max(1, slots)),
            "--swa-full",
            "--jinja",
            "--chat-template-kwargs", #"{"enable_thinking":false}"#,
            "--poll", "0",
            "--no-webui",
        ]
    }
}
