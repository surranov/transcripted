# Transcript LLM (fork)

## What this owns

A local LLM pass over finished speech, the fork's addition (`surranov/transcripted`), not upstream's:

- **Dictation:** before paste, the dictation prompt (Settings → Models and prompts) fixes recognition mistakes, terms and formatting.
- **Meetings:** after a meeting's transcript is saved and restyled, every utterance goes through the meeting prompt in the background and the corrected text replaces it in place (`Sources/Meeting/MeetingTranscriptLLMPass.swift`).

Pieces:

- Models: each pass picks its own (`TranscriptLLMModelPreference` in `Sources/Support/`, Settings next to its prompt): Gemma 4 E2B **instruction-tuned** Q4_0 from `ggml-org/gemma-4-E2B-it-GGUF` (default for dictation, about half E4B's time) or Gemma 4 E4B instruction-tuned QAT Q4_0 from `google/gemma-4-E4B-it-qat-q4_0-gguf` (default for meetings, better wording). Pinned by commit and SHA-256 in `TranscriptLLMModel.swift`, downloaded at launch or on a switch into `<app support>/models/transcript-llm/<id>/`. Switching a pass away from a model no pass runs anymore asks whether to delete it; nothing is deleted without that answer. Writing's model is the base E2B (autocomplete), which doesn't follow instructions; the two never share a file.
- Engine: a `llama-server` child per distinct model (`TranscriptLLMEngineLayout`) through Writing's `LlamaServerProcessHost` with the `.chat` launch profile (`Sources/TranscriptedWriting/Runtime/LlamaLaunchProfile.swift`): 16,384 tokens per slot, a slot per pass the helper serves (pinned per request with `id_slot`), Jinja chat template, thinking off, per-launch API key, Writing's restart policy and orphan reaping. Both passes on one model: one helper on 17893, slot 0 dictation, slot 1 meetings. Different models: dictation's on 17893, meetings' on 17894, a slot each. A model switch shuts the retiring helper down before its replacement starts. Writing's helper (17891) is untouched.
- Prompts: `TranscriptLLMPromptPreference` (`Sources/Support/`), `.dictation` and `.meeting`, 30,000-character cap sized against one slot's context. An empty prompt turns its pass off; there's no other toggle.

## Files

- `TranscriptLLMController.swift`: the runtime. `TranscriptedAppState` calls `start(log:)` at launch (not in launch-smoke mode), `handleSystemWake()` on wake and `stop()` at quit, and hands the controller to `MeetingTranscriptLLMWorker.shared.configure`. Reaps both ports, then runs the layout the saved model choices ask for and re-applies it on every switch. Retries each model's download with backoff, re-caches the prompts whenever a helper comes up or a prompt changes, deletes an unused model when Settings asks (`deleteUnusedModel`), and implements `DictationTextRefiner` (`Sources/Dictation/`).
- `TranscriptLLMController+Meeting.swift`: `MeetingUtteranceRefiner` (`Sources/Meeting/`). Waits while a dictation pass is in flight, so a dictation gets the GPU first.
- `TranscriptLLMChat.swift`: request body and answer parsing for `/v1/chat/completions`. Foundation-only; fast-tested.
- `TranscriptLLMEngineLayout.swift`: which helpers run, on which ports, and each pass's slot. Foundation-only; fast-tested.
- `TranscriptLLMModel.swift`: model descriptors, context size, model root, bytes on disk, retry delays.

## Rules

- **The pass never costs a dictation or a meeting.** Every outcome other than an accepted answer keeps the recognized text. An answer cut off at the token limit (`finish_reason` other than `stop`) or far off the original's length (`DictationTextRefinementPolicy`) is rejected.
- **A long dictation goes in pieces** (`DictationRefinementChunking`, past 3,000 characters), like a meeting goes per utterance: a rejected piece keeps its recognized text, the others are still refined, and the system prompt stays cached in the slot between them. The take length cap is a two-hour backstop (`TranscriptedConstants.dictationSessionMaxDuration`), so a single request could otherwise outgrow the 16k-token slot after about 40 minutes of speech.
- **Meetings are rewritten once, at the end, after a backup**, and only where the transcript still holds the text the model saw. Jobs and their progress are on disk (`state/meeting-llm/`), so a quit, crash or unready model resumes the job instead of losing it.
- **No timeout for dictation** (owner's call, 2026-10-10). Esc after the stop cancels the pass and saves the transcript without pasting (`DictationSessionController+TextRefinement.swift`).
- **Text stays local.** Logs carry counts, lengths and timings only, never transcript or prompt text. The helper listens on loopback behind a per-launch key.
- **The app reaches this module through `DictationTextRefiner` and `MeetingUtteranceRefiner`**, plus `statusLine(for:)`, `deleteUnusedModel` and `TranscriptLLMModel.bytesOnDisk` for Settings. UIOverlay and Meeting never name a type from here.

## Tests

`bash run-tests.sh --filter TranscriptLLM` (request/answer format, prompts, model choices, helper layout), `--filter DictationTextRefinement` (acceptance policy), `--filter MeetingTranscriptLLM` (meeting document rewrite, backup, checkpoint resume), `--filter DictationLeftoverRecovery`; `swift test --filter LlamaHelperLaunchFlags` (chat flags). The controller and helper need a real signed build: download, helper start, a dictation, Esc mid-pass, a meeting import, quit while a pass runs, a model switch each way (one helper ↔ two) and the delete question.
