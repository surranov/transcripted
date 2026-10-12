# Fork scripts

Personal fork of [r3dbars/transcripted](https://github.com/r3dbars/transcripted). These scripts build a **Transcripted Dev** variant that runs beside the official `/Applications/Transcripted.app` without sharing its data, preferences, permissions or updates.

```bash
bash scripts/fork/build-dev.sh               # build and install ~/Applications/Transcripted Dev.app
bash scripts/fork/test-dev-variant-plist.sh  # check the Info.plist overrides
bash scripts/fork/build-whisper-cpp.sh       # whisper.cpp for the Breeze model (build-dev.sh runs it)
```

`build-whisper-cpp.sh` builds whisper.cpp at a pinned release into `deps-whisper-cpp/` (its own folder, because `build-deps.sh` replaces `deps-libs`/`deps-modules` wholesale). The app links it only when it's there; without it the Breeze model shows as not built. The model itself is installed separately: `scripts/models/breeze-asr-25/README.md`.

## What the Dev variant changes

`dev-variant-plist.sh` edits the built bundle's Info.plist (build.sh calls it through `TRANSCRIPTED_PLIST_OVERRIDES`):

| Key | Dev value | Effect |
|---|---|---|
| `CFBundleIdentifier` | `dev.surranov.transcripted` | Own UserDefaults domain, TCC grants, login item, Writing suite (`<id>.writing`) |
| `CFBundleName`, `CFBundleDisplayName` | `Transcripted Dev` | Tells the two apps apart |
| `TranscriptedAppSupportFolderName` | `Transcripted Dev` | Data under `~/Library/Application Support/Transcripted Dev` |
| `SUFeedURL` | removed | Sparkle never starts, so an official update can't replace the Dev app |
| `TranscriptedSentryDSN`, `TranscriptedPostHog*` | removed | No crash reports or analytics to the upstream owner |

## Signing

`build-dev.sh` signs with the first valid `Apple Development` identity (override with `TRANSCRIPTED_DEV_SIGN_IDENTITY`), so permission grants survive rebuilds; without one it falls back to ad-hoc and macOS forgets the grants on every build. To get one: Xcode → Settings → Apple Accounts → add your Apple ID → Personal Team → Manage Certificates → + Apple Development. If `security find-identity -v -p codesigning` still shows 0 valid identities, the login keychain is missing the [Apple WWDR G3](https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer) intermediate: `security import AppleWWDRCAG3.cer -k ~/Library/Keychains/login.keychain-db`.

## Still shared, so don't use these in the Dev app

- **Writing** (keyboard, `Transcripted/writing` models, port 17891): it doesn't start because the Dev suite has no finished setup. Don't set it up in Dev.
- **FluidAudio models** in `~/Library/Application Support/FluidAudio/Models`: read-only sharing is fine; don't run model-cache cleanup from Dev.
- **Agent Connect**: it writes an MCP server named `transcripted` into `~/.claude.json` and other agent configs, replacing the official one.

After the first launch, change the Dev app's hotkeys and turn off call auto-detection, or both apps will grab the same keys and record the same call.

## Python on macOS 26.2

Homebrew's `python3` (3.14.7) can't `import plistlib` on macOS 26.2: its `pyexpat` needs a newer system `libexpat`. `build-dev.sh` puts `~/.local/share/transcripted-dev/bin/python3` (a standalone CPython from `uv python install 3.14`) first on `PATH` when it exists. Updating macOS to 26.4+ removes the need.
