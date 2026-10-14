import Foundation

// Which llama-server helpers run for the transcript LLM: a model is loaded
// once however many passes run it, each pass keeps a slot of its own on its
// model's helper, and helpers never share a port with each other or with
// Writing's.

func testTranscriptLLMEngineLayout() {
    runSuite("TranscriptLLMEngineLayout shares one helper when both passes run one model") {
        for model in TranscriptLLMModelChoice.allCases {
            let layout = TranscriptLLMEngineLayout(dictation: model, meeting: model)
            assertEqual(layout.engines.count, 1, "\(model.rawValue): loaded once")
            let dictation = layout.engine(for: .dictation)
            let meeting = layout.engine(for: .meeting)
            assertEqual(dictation, meeting, "\(model.rawValue): both passes on the same helper")
            assertEqual(dictation?.model, model, "\(model.rawValue): the picked model")
            assertEqual(dictation?.slot(of: .dictation), 0, "dictation keeps slot 0")
            assertEqual(meeting?.slot(of: .meeting), 1, "meetings keep slot 1, so neither waits on the other's cache")
        }
    }

    runSuite("TranscriptLLMEngineLayout runs a helper per model when the passes differ") {
        let layout = TranscriptLLMEngineLayout(dictation: .gemma4E2B, meeting: .gemma4E4B)
        assertEqual(layout.engines.count, 2, "one helper per model")
        let dictation = layout.engine(for: .dictation)
        let meeting = layout.engine(for: .meeting)
        assertEqual(dictation?.model, .gemma4E2B, "dictation on its model")
        assertEqual(meeting?.model, .gemma4E4B, "meetings on theirs")
        assertEqual(dictation?.passes, [.dictation], "the dictation helper serves dictation only")
        assertEqual(meeting?.passes, [.meeting], "the meeting helper serves meetings only")
        assertEqual(dictation?.slot(of: .dictation), 0, "a single-pass helper's slot")
        assertEqual(meeting?.slot(of: .meeting), 0, "a single-pass helper's slot")
        assertTrue(dictation?.port != meeting?.port, "two helpers, two ports")
    }

    runSuite("TranscriptLLMEngineLayout keeps the dictation helper's port across switches") {
        let shared = TranscriptLLMEngineLayout(dictation: .gemma4E2B, meeting: .gemma4E2B)
        let split = TranscriptLLMEngineLayout(dictation: .gemma4E2B, meeting: .gemma4E4B)
        assertEqual(shared.engine(for: .dictation)?.port, split.engine(for: .dictation)?.port, "dictation's port doesn't move")
        assertTrue(shared != split, "a meeting switch changes the layout, so the runtime applies it")
        assertEqual(
            TranscriptLLMEngineLayout(dictation: .gemma4E2B, meeting: .gemma4E4B),
            split,
            "the same picks give the same layout, so nothing restarts"
        )
    }

    runSuite("TranscriptLLMEngineLayout ports stay off Writing's helper and each other") {
        let ports = TranscriptLLMEngineLayout.ports
        assertEqual(Set(ports).count, ports.count, "distinct ports")
        assertFalse(ports.contains(17_891), "Writing's helper keeps 17891")
        for dictation in TranscriptLLMModelChoice.allCases {
            for meeting in TranscriptLLMModelChoice.allCases {
                let layout = TranscriptLLMEngineLayout(dictation: dictation, meeting: meeting)
                assertTrue(layout.engines.allSatisfy { ports.contains($0.port) }, "every helper on a reaped port")
                assertEqual(Set(layout.engines.map(\.port)).count, layout.engines.count, "no two helpers share a port")
                for pass in TranscriptLLMPass.allCases {
                    assertTrue(layout.engine(for: pass) != nil, "\(pass.rawValue) always has a helper")
                }
            }
        }
    }

    runSuite("TranscriptLLMEngineLayout runs only the picked models") {
        let layout = TranscriptLLMEngineLayout(dictation: .gemma4E4B, meeting: .gemma4E4B)
        assertTrue(layout.runs(.gemma4E4B), "the picked model runs")
        assertFalse(layout.runs(.gemma4E2B), "a model no pass picked doesn't")
    }

    runSuite("TranscriptLLMEngineLayout reads the saved picks") {
        let name = "TranscriptLLMEngineLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        assertEqual(
            TranscriptLLMEngineLayout(userDefaults: defaults),
            TranscriptLLMEngineLayout(dictation: .gemma4E2B, meeting: .gemma4E4B),
            "nothing saved: each pass on its default model"
        )
        TranscriptLLMModelPreference.meeting.setChoice(.gemma4E2B, userDefaults: defaults)
        assertEqual(TranscriptLLMEngineLayout(userDefaults: defaults).engines.count, 1, "meetings moved onto dictation's model")
    }
}
