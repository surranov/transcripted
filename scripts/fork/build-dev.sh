#!/bin/bash
# Builds the fork's "Transcripted Dev" variant and installs it as
# ~/Applications/Transcripted Dev.app, beside the official /Applications/Transcripted.app.
# What makes it independent of the official app: dev-variant-plist.sh.
#
# Usage: bash scripts/fork/build-dev.sh [extra build.sh args]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# Homebrew's python3 on macOS 26.2 can't import plistlib (its pyexpat wants a
# newer system libexpat), and build.sh runs python3. Prefer the standalone
# interpreter linked here when it exists; see scripts/fork/README.md.
PY_SHIM_DIR="$HOME/.local/share/transcripted-dev/bin"
if [ -x "$PY_SHIM_DIR/python3" ]; then
    export PATH="$PY_SHIM_DIR:$PATH"
fi

DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/Transcripted Dev.app"
if pgrep -f "$DEST/Contents/MacOS/" >/dev/null; then
    echo "Transcripted Dev is running; quit it before rebuilding." >&2
    exit 1
fi

# A stable signing identity keeps macOS permission grants (microphone,
# Accessibility, screen and system audio) across rebuilds; an ad-hoc signature
# changes every build and macOS forgets them. A free Personal Team
# "Apple Development" certificate from Xcode is enough: local.plist asks only
# for entitlements that need no provisioning profile.
SIGN_IDENTITY_WANTED="${TRANSCRIPTED_DEV_SIGN_IDENTITY:-Apple Development}"
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY_WANTED"; then
    export SIGN_IDENTITY="$SIGN_IDENTITY_WANTED"
else
    echo "⚠️  No valid \"$SIGN_IDENTITY_WANTED\" signing identity: signing ad-hoc, so permissions reset on every rebuild." >&2
    unset SIGN_IDENTITY SIGNING_IDENTITY
fi

TRANSCRIPTED_PLIST_OVERRIDES="$REPO_ROOT/scripts/fork/dev-variant-plist.sh" \
TRANSCRIPTED_SKIP_LAUNCH_SMOKE=1 \
    bash build.sh --no-open "$@"

# Never install a bundle that would share the official app's identity.
BUILT="$REPO_ROOT/build/Transcripted.app"
built_id="$(plutil -extract CFBundleIdentifier raw "$BUILT/Contents/Info.plist")"
built_folder="$(plutil -extract TranscriptedAppSupportFolderName raw "$BUILT/Contents/Info.plist" 2>/dev/null || true)"
if [ "$built_id" = "com.justinbetker.draft" ] || [ -z "$built_folder" ]; then
    echo "Built bundle is not the Dev variant (id $built_id); not installing." >&2
    exit 1
fi

mkdir -p "$DEST_DIR"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
echo "Installed $DEST ($built_id)"
