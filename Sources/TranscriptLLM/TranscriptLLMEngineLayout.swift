import Foundation

/// Which `llama-server` helpers the transcript LLM runs and where each pass
/// goes: one helper per distinct model the passes picked
/// (`TranscriptLLMModelPreference`). Both passes on one model share its
/// helper, a slot each, so the model is loaded once; different models get a
/// helper each. Foundation-only; fast-tested.
struct TranscriptLLMEngineLayout: Equatable, Sendable {
    struct Engine: Equatable, Sendable {
        let model: TranscriptLLMModelChoice
        let port: Int
        /// In slot order: a pass's `id_slot` is its index here. Each slot
        /// keeps its own cached prompt, so dictation never waits behind a
        /// long meeting pass on a shared helper.
        let passes: [TranscriptLLMPass]

        func slot(of pass: TranscriptLLMPass) -> Int {
            // `engine(for:)` only returns engines that serve the pass.
            passes.firstIndex(of: pass) ?? 0
        }
    }

    /// Writing's helper is on 17891 (`TildeProductProfile.llamaServerPort`).
    /// The dictation model's helper takes the first port, a meeting model
    /// of its own the second. Hosts never touch a listener that isn't their
    /// own re-parented helper; a foreign one keeps that engine off and
    /// retrying.
    static let ports = [17_893, 17_894]

    let engines: [Engine]

    init(dictation: TranscriptLLMModelChoice, meeting: TranscriptLLMModelChoice) {
        engines = dictation == meeting
            ? [Engine(model: dictation, port: Self.ports[0], passes: [.dictation, .meeting])]
            : [
                Engine(model: dictation, port: Self.ports[0], passes: [.dictation]),
                Engine(model: meeting, port: Self.ports[1], passes: [.meeting]),
            ]
    }

    init(userDefaults: UserDefaults = .standard) {
        self.init(
            dictation: TranscriptLLMModelPreference.dictation.choice(userDefaults: userDefaults),
            meeting: TranscriptLLMModelPreference.meeting.choice(userDefaults: userDefaults)
        )
    }

    func engine(for pass: TranscriptLLMPass) -> Engine? {
        engines.first { $0.passes.contains(pass) }
    }

    func runs(_ model: TranscriptLLMModelChoice) -> Bool {
        engines.contains { $0.model == model }
    }
}
