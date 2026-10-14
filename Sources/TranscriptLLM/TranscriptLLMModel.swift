import Foundation

/// The transcript LLM's models and helper settings.
enum TranscriptLLMModel {
    /// Instruction-tuned Gemma 4 builds only: Writing's model is the *base*
    /// E2B (autocomplete), which doesn't follow instructions, so the two never
    /// share a file. Pinned by commit and SHA-256 like every Writing model;
    /// the bytes are the trust boundary.
    static func descriptor(for model: TranscriptLLMModelChoice) -> ModelDescriptor {
        switch model {
        case .gemma4E2B:
            // Q4_0 by ggml-org: the build benchmarked on the owner's
            // dictations against Superwhisper's references (2026-10-10).
            ModelDescriptor(
                identifier: model.rawValue,
                version: "b4243c156154b6dca9324415f8c7ccc098b4aed1",
                repository: "ggml-org/gemma-4-E2B-it-GGUF",
                revision: "b4243c156154b6dca9324415f8c7ccc098b4aed1",
                fileName: "gemma-4-E2B-it-Q4_0.gguf",
                expectedBytes: 2_841_481_184,
                sha256: "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52"
            )
        case .gemma4E4B:
            // Google's own quantization-aware-trained Q4_0, the build scored
            // on the same dictations (2026-10-13).
            ModelDescriptor(
                identifier: model.rawValue,
                version: "4b4a2c1d584be7264f87aac328a1bc739ce81b6c",
                repository: "google/gemma-4-E4B-it-qat-q4_0-gguf",
                revision: "4b4a2c1d584be7264f87aac328a1bc739ce81b6c",
                fileName: "gemma-4-E4B_q4_0-it.gguf",
                expectedBytes: 5_154_941_280,
                sha256: "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee"
            )
        }
    }

    /// Per slot. See `TranscriptLLMPromptPreference.maxCharacters` for how
    /// the prompt limit was sized against this. A second 16k-token slot on a
    /// shared helper costs ~0.3 GB (measured on E2B: 475 → 765 MB footprint).
    static let contextTokens = 16_384

    static let diagnosticsLabel = "transcript-llm"

    /// `<app support>/models/transcript-llm`, next to Writing's
    /// `models/writing`; one folder per model (`<identifier>/model.gguf`).
    static var modelRoot: URL {
        FileManager.default.transcriptedAppSupportRootURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("transcript-llm", isDirectory: true)
    }

    /// Bytes a model takes in its folder: the verified file and any resumable
    /// partial download. Zero when there's nothing to delete.
    static func bytesOnDisk(_ model: TranscriptLLMModelChoice) -> Int64 {
        let folder = modelRoot.appendingPathComponent(model.rawValue, isDirectory: true)
        return ["model.gguf", "model.gguf.partial"].reduce(0) { total, name in
            let path = folder.appendingPathComponent(name, isDirectory: false).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return total + size
        }
    }

    /// Waits between model download attempts after the manager's own quick
    /// retries are spent (offline, disk full, server error). The last one
    /// repeats; each dictation also asks for an early retry.
    static let downloadRetryDelays: [Duration] = [
        .seconds(60), .seconds(120), .seconds(300), .seconds(900),
    ]
}
