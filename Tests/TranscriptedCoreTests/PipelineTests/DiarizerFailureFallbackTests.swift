import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

/// A broken diarizer costs speaker labels, not the meeting. These tests pin
/// that a diarization failure still yields a saved transcript (call side as one
/// unnamed speaker, or the mic as one "You"), that nothing here hides a
/// failure of speech-to-text itself, and that cancellation still propagates.
@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testSystemDiarizerFailureStillSavesTheCallSideWithoutSpeakerLabels() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Remote speech survived the broken diarizer."),
            diarization: ThrowingDiarizationEngine(error: DiarizerFailureFixtureError.inference)
        )
        let systemURL = try makeSpeechLikeAudio(named: "call.wav", seconds: 6)

        manager.startTranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty, "nothing failed: the words were read")
        let markdown = try String(contentsOf: try XCTUnwrap(manager.lastSavedTranscriptURL), encoding: .utf8)
        XCTAssertTrue(markdown.contains("Remote speech survived the broken diarizer."))
        XCTAssertTrue(markdown.contains("Speaker 1"), "all call-side words share one unnamed speaker")
        XCTAssertTrue(
            markdown.contains("diarization_engine: none"),
            "no diarizer ran, so the transcript must not name one"
        )
    }

    func testSystemDiarizerFailureKeepsTheMicWordsToo() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Both sides were transcribed anyway."),
            diarization: ThrowingDiarizationEngine(error: DiarizerFailureFixtureError.inference)
        )
        let systemURL = try makeSpeechLikeAudio(named: "call.wav", seconds: 6)
        let micURL = try makeSpeechLikeAudio(named: "mic.wav", seconds: 6)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }
        let markdown = try String(contentsOf: try XCTUnwrap(manager.lastSavedTranscriptURL), encoding: .utf8)
        XCTAssertTrue(markdown.contains("### Microphone") || markdown.contains("You"), "the mic side is in the transcript")
        XCTAssertTrue(markdown.contains("Speaker 1"), "and so is the call side")
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
    }

    func testMicDiarizerFailureWithLocalSpeakerSplitStillSavesTheMicAsOneSpeaker() async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "My own words were kept."),
            diarization: ThrowingDiarizationEngine(error: DiarizerFailureFixtureError.inference)
        )
        let micURL = try makeSpeechLikeAudio(named: "mic.wav", seconds: 6)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            splitLocalSpeakers: true
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }
        let markdown = try String(contentsOf: try XCTUnwrap(manager.lastSavedTranscriptURL), encoding: .utf8)
        XCTAssertTrue(markdown.contains("My own words were kept."))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
    }

    func testMicSplitFailureWithAnEmptyCallSideStillSavesTheMic() async throws {
        // The call side was silent (the diarizer says so), then the mic
        // diarizer broke. Nothing from the call side is there to fall back
        // on, and the mic is the whole meeting.
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "The mic carried the whole meeting."),
            diarization: ThrowingDiarizationEngine(errors: [
                DiarizationResultError.noSpeechDetected,
                DiarizerFailureFixtureError.inference,
            ])
        )
        let systemURL = try makeSilentAudio(named: "silent-call.wav", seconds: 6)
        let micURL = try makeSpeechLikeAudio(named: "mic.wav", seconds: 6)

        manager.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            splitLocalSpeakers: true
        )

        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }
        let markdown = try String(contentsOf: try XCTUnwrap(manager.lastSavedTranscriptURL), encoding: .utf8)
        XCTAssertTrue(markdown.contains("The mic carried the whole meeting."))
        XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
    }

    func testBrokenDiarizerAndBrokenSpeechToTextStillQueuesTheAudioForRetry() async throws {
        let retained = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcribeError: DiarizerFailureFixtureError.inference),
            diarization: ThrowingDiarizationEngine(error: DiarizerFailureFixtureError.inference),
            retainedAudioDirectory: retained
        )
        let systemURL = try makeSpeechLikeAudio(named: "call.wav", seconds: 6)

        manager.startTranscription(
            micURL: nil,
            systemURL: systemURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        try await waitUntil {
            manager.activeCount == 0 && manager.failedTranscriptionManager.failedTranscriptions.count == 1
        }
        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(failed.isRetryable)
        XCTAssertTrue(failed.audioFilesExist(), "the fallback must never hide a failure that has no words to save")
        XCTAssertNil(manager.lastSavedTranscriptURL)
    }

    func testDiarizerFallbackPolicyNeverSwallowsCancellationOrTheNoSpeechResult() {
        XCTAssertFalse(Transcription.shouldTranscribeWithoutDiarization(after: CancellationError()))
        XCTAssertFalse(Transcription.shouldTranscribeWithoutDiarization(after: PipelineError.noSpeechDetected))
        XCTAssertFalse(Transcription.shouldTranscribeWithoutDiarization(after: DiarizationResultError.noSpeechDetected))
        XCTAssertTrue(Transcription.shouldTranscribeWithoutDiarization(after: DiarizerFailureFixtureError.inference))
        XCTAssertTrue(Transcription.shouldTranscribeWithoutDiarization(after: PipelineError.modelNotLoaded(model: "Diarization")))
    }

    func testCallSideIsReadAgainWhenItsDiarizerFailedEvenIfTheMicHasWords() {
        // (system words, mic words, usable system audio, diarizer failed) -> sweep the call side?
        let cases: [(Int, Int, Bool, Bool, Bool)] = [
            (0, 0, true, false, true),   // empty meeting: the old last-chance rule
            (0, 4, true, false, false),  // mic carried it; a quiet call side is not worth a second STT run
            (0, 4, true, true, true),    // diarizer failed: the call side has no words at all
            (3, 0, true, true, false),   // words already exist: never replace them
            (0, 0, false, true, false),  // no usable call audio: nothing to read
        ]
        for (system, mic, usable, failed, expected) in cases {
            XCTAssertEqual(
                Transcription.lastChanceSweepsSystem(
                    systemUtteranceCount: system,
                    micUtteranceCount: mic,
                    hasUsableSystemAudio: usable,
                    systemDiarizationFailed: failed
                ),
                expected,
                "system \(system), mic \(mic), usable \(usable), diarizer failed \(failed)"
            )
        }
    }

    private func makeSilentAudio(named name: String, seconds: Double) throws -> URL {
        let directory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try writeMonoWAV(to: url, duration: seconds, amplitude: 0)
        return url
    }

    /// Bursts of tone separated by silence: the rise and fall the last-chance
    /// pass needs before it spends any STT on a track.
    private func makeSpeechLikeAudio(named name: String, seconds: Double) throws -> URL {
        let directory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let sampleRate = 16_000.0
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let frames = Int(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        let burstFrames = Int(0.2 * sampleRate)
        for index in 0..<frames {
            let inBurst = (index / burstFrames) % 2 == 0
            samples[index] = inBurst
                ? 0.2 * Float(sin(2 * Double.pi * 200 * Double(index) / sampleRate))
                : 0
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
        file.close()
        return url
    }
}

private enum DiarizerFailureFixtureError: Error {
    case inference
}

/// Throws on every diarization call: the same error each time, or one error
/// per call in order (the last one repeats).
@available(macOS 14.0, *)
@MainActor
private final class ThrowingDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private let errors: [Error]
    private var calls = 0

    init(error: Error) {
        self.errors = [error]
    }

    init(errors: [Error]) {
        self.errors = errors
    }

    private func nextError() -> Error {
        defer { calls += 1 }
        return errors[min(calls, errors.count - 1)]
    }

    func initialize() async {}
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { throw nextError() }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { throw nextError() }
    func cleanup() {}
}
