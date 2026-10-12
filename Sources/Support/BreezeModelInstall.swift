import Foundation

/// Fork: where Breeze-ASR-25 lives once `scripts/models/breeze-asr-25/install.sh`
/// has installed it. Breeze is MediaTek's Whisper large-v2 fine-tune for speech
/// that switches languages mid-sentence; Transcripted runs its whisper.cpp
/// build (q8 weights plus a Core ML encoder for the Neural Engine).
///
/// Like Parakeet Ultra it is never downloaded by the app and never bundled,
/// and it sits under the local models folder, not `cache/whisperkit`, so the
/// Whisper cache cleanup in Settings can't delete it.
enum BreezeModelInstall {
    static let directoryName = "breeze-asr-25"
    static let weightsFileName = "ggml-breeze-asr-25-q8_0.bin"
    /// whisper.cpp looks for `<weights name without -q8_0 and .bin>-encoder.mlmodelc`
    /// next to the weights and runs the encoder through Core ML when it's there.
    static let coreMLEncoderDirectoryName = "ggml-breeze-asr-25-encoder.mlmodelc"
    /// Written last by the install script, so a half-copied folder never counts.
    static let markerFileName = ParakeetModelVariant.localInstallMarkerFileName

    /// Path-free status texts; the model card shows only these, never raw
    /// whisper.cpp or Core ML output.
    static let notInstalledMessage = "Breeze ASR 25 isn't installed. Install it with scripts/models/breeze-asr-25/install.sh."
    static let notBuiltMessage = "This build has no whisper.cpp, which Breeze needs. Rebuild with scripts/fork/build-dev.sh."
    static let loadFailedMessage = "Breeze ASR 25 is installed but couldn't load. Reinstall it with scripts/models/breeze-asr-25/install.sh."
    static var knownMessages: [String] { [notInstalledMessage, notBuiltMessage, loadFailedMessage] }

    /// The q8 weights are about 1.6 GB; anything far smaller is a broken copy.
    static let minimumWeightsBytes: Int64 = 1_000_000_000

    static func directory(modelsRoot: URL = ModelCacheInventory.defaultLocalModelsDirectory()) -> URL {
        modelsRoot.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func weightsURL(modelsRoot: URL = ModelCacheInventory.defaultLocalModelsDirectory()) -> URL {
        directory(modelsRoot: modelsRoot).appendingPathComponent(weightsFileName, isDirectory: false)
    }

    /// A few `stat` calls; cheap enough for the model picker to ask on refresh.
    static func isInstalled(
        modelsRoot: URL = ModelCacheInventory.defaultLocalModelsDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        let folder = directory(modelsRoot: modelsRoot)
        let encoder = folder.appendingPathComponent(coreMLEncoderDirectoryName, isDirectory: true)
        let required = [
            folder.appendingPathComponent(markerFileName),
            encoder.appendingPathComponent("coremldata.bin"),
            encoder.appendingPathComponent("weights/weight.bin"),
        ]
        guard required.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) else { return false }
        let weights = weightsURL(modelsRoot: modelsRoot)
        guard let size = (try? fileManager.attributesOfItem(atPath: weights.path))?[.size] as? NSNumber else {
            return false
        }
        return size.int64Value >= minimumWeightsBytes
    }
}
