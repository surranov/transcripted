# Transcript LLM (fork)

## What this owns

A local LLM pass over finished speech, the fork's addition (`surranov/transcripted`), not upstream's:

- **Dictation:** before paste, the dictation prompt (Settings → Local LLM) fixes recognition mistakes, terms and formatting.
- **Meetings:** after a meeting's transcript is saved and restyled, every utterance goes through the meeting prompt in the background and the corrected text replaces it in place (`Sources/Meeting/MeetingTranscriptLLMPass.swift`).

Pieces:

- Model: Gemma 4 E2B **instruction-tuned**, Q4_0 from `ggml-org/gemma-4-E2B-it-GGUF`, pinned by commit and SHA-256 in `TranscriptLLMModel.swift`. Downloaded once, at launch, into `<app support>/models/transcript-llm/`. Writing's model is the base E2B (autocomplete), which doesn't follow instructions; the two never share a file.
- Engine: its own `llama-server` child through Writing's `LlamaServerProcessHost` with the `.chat` launch profile (`Sources/TranscriptedWriting/Runtime/LlamaLaunchProfile.swift`): port 17893, two slots of 16,384 tokens (slot 0 dictation, slot 1 meetings, pinned per request with `id_slot`), Jinja chat template, thinking off, per-launch API key, Writing's restart policy and orphan reaping. Writing's helper (17891) is untouched.
- Prompts: `TranscriptLLMPromptPreference` (`Sources/Support/`), `.dictation` and `.meeting`, 30,000-character cap sized against one slot's context. An empty prompt turns its pass off; there's no other toggle.

## Files

- `TranscriptLLMController.swift`: the runtime. `TranscriptedAppState` calls `start(log:)` at launch (not in launch-smoke mode), `handleSystemWake()` on wake and `stop()` at quit, and hands the controller to `MeetingTranscriptLLMWorker.shared.configure`. Retries the model download with backoff, re-caches both prompts whenever the helper comes up or a prompt changes, and implements `DictationTextRefiner` (`Sources/Dictation/`).
- `TranscriptLLMController+Meeting.swift`: `MeetingUtteranceRefiner` (`Sources/Meeting/`). Waits while a dictation pass is in flight, so a dictation gets the GPU first.
- `TranscriptLLMChat.swift`: request body and answer parsing for `/v1/chat/completions`. Foundation-only; fast-tested.
- `TranscriptLLMModel.swift`: model descriptor, port, context size, slots, model root, retry delays.

## Rules

- **The pass never costs a dictation or a meeting.** Every outcome other than an accepted answer keeps the recognized text. An answer cut off at the token limit (`finish_reason` other than `stop`) or far off the original's length (`DictationTextRefinementPolicy`) is rejected.
- **Meetings are rewritten once, at the end, after a backup**, and only where the transcript still holds the text the model saw. Jobs and their progress are on disk (`state/meeting-llm/`), so a quit, crash or unready model resumes the job instead of losing it.
- **No timeout for dictation** (owner's call, 2026-10-10). Esc after the stop cancels the pass and saves the transcript without pasting (`DictationSessionController+TextRefinement.swift`).
- **Text stays local.** Logs carry counts, lengths and timings only, never transcript or prompt text. The helper listens on loopback behind a per-launch key.
- **The app reaches this module through `DictationTextRefiner` and `MeetingUtteranceRefiner`**, plus `statusLine` for Settings. UIOverlay and Meeting never name a type from here.

## Tests

`bash run-tests.sh --filter TranscriptLLM` (request/answer format, prompts), `--filter DictationTextRefinement` (acceptance policy), `--filter MeetingTranscriptLLM` (meeting document rewrite, backup, checkpoint resume), `--filter DictationLeftoverRecovery`; `swift test --filter LlamaHelperLaunchFlags` (chat flags). The controller and helper need a real signed build: download, helper start, a dictation, Esc mid-pass, a meeting import, quit while a pass runs.
