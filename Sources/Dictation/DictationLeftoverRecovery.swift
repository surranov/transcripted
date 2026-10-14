import Foundation

/// Launch: turns dictation audio an earlier run left behind into saved
/// Dictations (fork).
///
/// A take's WAV checkpoint is written before transcription and retired only
/// once its transcript is saved, so a checkpoint still on disk at launch is a
/// take whose words were never saved: the app crashed or was quit while it
/// transcribed, the model failed, or the take came back empty. Upstream
/// deleted the ones under 30 s at launch ("cheaper to say again") and kept
/// the rest with no way back in. The user may never have heard that the take
/// failed, so launch transcribes each one again and saves it as a "Saved
/// only" entry dated when it was spoken. A take that still yields nothing
/// keeps its WAV and is tried again next launch, until it is
/// `maximumAge` old.
enum DictationLeftoverRecovery {
    /// Unrecovered leftovers older than this are deleted at launch
    /// (`DictationStoppedAudioRecoveryStore.purgeLeftovers(onlyShortTakes:)`):
    /// a month of retries is enough, and private audio shouldn't pile up.
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60

    /// Shown as the entry's source app, so the list says where it came from.
    static let sourceAppName = "Recovered after restart"

    struct Steps {
        /// Checkpoints left by earlier runs, in the order to save them.
        var pending: () -> [DictationStoppedAudioRecovery]
        var loadSamples: (URL) async throws -> [Float]
        var transcribe: ([Float]) async throws -> String
        /// Fork: the model `transcribe` runs, for the text versions' label.
        var recognitionModel: () async -> String? = { nil }
        /// The live take's text cleanup (filler cleanup when it's on).
        var clean: (String) -> String
        /// The transcript LLM pass; anything but `.refined` keeps the
        /// recognized text.
        var refine: (String) async -> DictationTextRefinement
        /// Saves the entry with its text versions (fork) and retires the
        /// checkpoint; true when saved.
        var save: (DictationStoppedAudioRecovery, String, [DictationTextVersion]) async -> Bool
    }

    struct Summary: Equatable {
        var recovered = 0
        /// Transcribed to nothing; the WAV stays for a later launch.
        var noWords = 0
        /// Unreadable audio, a busy or failing model, or a failed save; the
        /// WAV stays.
        var failed = 0
    }

    static func run(_ steps: Steps) async -> Summary {
        var summary = Summary()
        for recovery in steps.pending() {
            if Task.isCancelled { break }
            do {
                let samples = try await steps.loadSamples(recovery.url)
                guard !samples.isEmpty else {
                    summary.failed += 1
                    continue
                }
                let recognitionModel = await steps.recognitionModel()
                let text = steps.clean(try await steps.transcribe(samples))
                guard !text.isEmpty else {
                    summary.noWords += 1
                    continue
                }
                let refinement = await steps.refine(text)
                let versions = DictationTextVersion.take(
                    recognized: text, recognitionModel: recognitionModel, refinement: refinement
                )
                if await steps.save(recovery, refinement.text(original: text), versions) {
                    summary.recovered += 1
                } else {
                    summary.failed += 1
                }
            } catch {
                summary.failed += 1
            }
        }
        return summary
    }

    /// Launch recovery isn't in a hurry, and it starts while the transcript
    /// LLM is still loading: a refiner that isn't ready yet is asked again
    /// every `delay`, up to `attempts` times, before the take is saved as
    /// recognized. Any other outcome (refined, no prompt, failed, rejected)
    /// is final.
    static func refineWhenReady(
        _ text: String,
        attempts: Int = 36,
        delay: Duration = .seconds(5),
        refine: (String) async -> DictationTextRefinement
    ) async -> DictationTextRefinement {
        for attempt in 1...max(1, attempts) {
            let refinement = await refine(text)
            guard refinement == .unchanged(.notReady), attempt < attempts, !Task.isCancelled else {
                return refinement
            }
            try? await Task.sleep(for: delay)
        }
        return .unchanged(.notReady)
    }

    /// The checkpoints launch should try, oldest first so the day files read
    /// in the order the takes were spoken: written before this launch, so
    /// none belongs to a take this run is still finishing.
    static func earlierRuns(
        _ recoveries: [DictationStoppedAudioRecovery],
        launchedAt: Date
    ) -> [DictationStoppedAudioRecovery] {
        recoveries.filter { $0.createdAt < launchedAt }.sorted { $0.createdAt < $1.createdAt }
    }
}
