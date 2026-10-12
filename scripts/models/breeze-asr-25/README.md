# Breeze-ASR-25 (fork, experimental)

[MediaTek Research's Breeze-ASR-25](https://huggingface.co/MediaTek-Research/Breeze-ASR-25) is a Whisper large-v2 fine-tune for speech that switches languages mid-sentence (Apache-2.0). On 132 of the owner's Russian dictations with English terms (2026-10-12, against ElevenLabs Scribe on the same audio) it kept 77% of English terms in Latin letters versus Parakeet V3's 26%, with fewer word errors (17.1% vs 18.9%).

Transcripted runs a whisper.cpp build of it ([`shdennlin/breeze-asr-25-ggml`](https://huggingface.co/shdennlin/breeze-asr-25-ggml), q8 weights plus a Core ML encoder for the Neural Engine) inside the app.

```bash
bash scripts/fork/build-whisper-cpp.sh                       # once per checkout (build-dev.sh runs it)
bash scripts/models/breeze-asr-25/install.sh --app "Transcripted Dev"
```

`install.sh` downloads ~2.9 GB at a pinned revision, checks every file's SHA-256, and swaps the folder in atomically under `~/Library/Application Support/<app>/models/breeze-asr-25`; `--from DIR` copies already-downloaded files instead. The marker `transcripted-model.json` is written last; the app ignores a folder without it. Then pick "Breeze ASR 25 (Experimental)" in Settings > General > Model. The first load compiles the Core ML encoder for this Mac once.

How dictation uses it: the take is transcribed in pieces while you talk, cut only at pauses, so Stop waits for the last piece only (about 0.5 s at any length in the evaluation). Any doubt falls back to transcribing the whole take. See `Sources/Speech/AGENTS.md` (Breeze).

To remove it: quit the app and delete the `breeze-asr-25` folder.
