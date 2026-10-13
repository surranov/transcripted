import Foundation

/// The transcript LLM's model and helper settings.
enum TranscriptLLMModel {
    /// Gemma 4 E4B instruction-tuned, Google's QAT Q4_0. On the owner's
    /// 155 s test dictation and six real raw dictations (2026-10-13, same
    /// prompt, same helper flags) it scored 92% and 97% to E2B's 86% and 97%,
    /// kept colloquial wording that E2B rewrote, and held its formatting when
    /// the prompt was edited; it takes about twice E2B's time (12 s vs 7 s for
    /// that dictation). Writing's model is the *base* E2B, which doesn't follow
    /// instructions, so the two can't share a file. Pinned by commit and
    /// SHA-256 like every Writing model; the bytes are the trust boundary.
    static let descriptor = ModelDescriptor(
        identifier: "gemma-4-e4b-it-qat-q4_0",
        version: "4b4a2c1d584be7264f87aac328a1bc739ce81b6c",
        repository: "google/gemma-4-E4B-it-qat-q4_0-gguf",
        revision: "4b4a2c1d584be7264f87aac328a1bc739ce81b6c",
        fileName: "gemma-4-E4B_q4_0-it.gguf",
        expectedBytes: 5_154_941_280,
        sha256: "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee"
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
    /// 16k-token slot cost ~0.3 GB with E2B (measured: 475 → 765 MB
    /// footprint); E4B with both slots measured ~2.0 GB.
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
