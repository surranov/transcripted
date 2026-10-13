import Foundation

/// The transcript LLM's model and helper settings.
enum TranscriptLLMModel {
    /// Gemma 4 E2B instruction-tuned, Q4_0 by ggml-org: the build benchmarked
    /// on the owner's dictations against Superwhisper's references
    /// (2026-10-10). Writing's model is the *base* E2B, which doesn't follow
    /// instructions, so the two can't share a file. Pinned by commit and
    /// SHA-256 like every Writing model; the bytes are the trust boundary.
    static let descriptor = ModelDescriptor(
        identifier: "gemma-4-e2b-it-q4_0",
        version: "b4243c156154b6dca9324415f8c7ccc098b4aed1",
        repository: "ggml-org/gemma-4-E2B-it-GGUF",
        revision: "b4243c156154b6dca9324415f8c7ccc098b4aed1",
        fileName: "gemma-4-E2B-it-Q4_0.gguf",
        expectedBytes: 2_841_481_184,
        sha256: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
    )

    /// Writing's helper is on 17891 (`TildeProductProfile.llamaServerPort`).
    /// The host never touches a listener that isn't its own re-parented
    /// helper; a foreign one keeps this engine off and retrying.
    static let port = 17_893

    /// Per slot. See `TranscriptLLMPromptPreference.maxCharacters` for how
    /// the prompt limit was sized against this.
    static let contextTokens = 16_384

    /// The helper's slots, pinned per caller with `id_slot`: dictation keeps
    /// its own cached prompt and never waits behind a long meeting pass (the
    /// app records and transcribes a meeting while you dictate). A second
    /// 16k-token slot costs ~0.3 GB (measured: 475 → 765 MB footprint).
    enum Slot: Int, CaseIterable {
        case dictation = 0
        case meeting = 1
    }

    static let diagnosticsLabel = "transcript-llm"

    /// `<app support>/models/transcript-llm`, next to Writing's
    /// `models/writing`.
    static var modelRoot: URL {
        FileManager.default.transcriptedAppSupportRootURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("transcript-llm", isDirectory: true)
    }

    /// Waits between model download attempts after the manager's own quick
    /// retries are spent (offline, disk full, server error). The last one
    /// repeats; each dictation also asks for an early retry.
    static let downloadRetryDelays: [Duration] = [
        .seconds(60), .seconds(120), .seconds(300), .seconds(900),
    ]
}
