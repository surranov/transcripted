#!/bin/bash
# Checks dev-variant-plist.sh against a copy of the repo's Info.plist:
# the Dev identity is set, update/telemetry keys are gone, and unsafe
# overrides are refused before they can touch the plist.
#
# Usage: bash scripts/fork/test-dev-variant-plist.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/fork/dev-variant-plist.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/dev-variant-plist.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failures=0

check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1: got '$2', want '$3'"
        failures=$((failures + 1))
    fi
}
value() { plutil -extract "$1" raw "$2" 2>/dev/null || echo "<missing>"; }

plist="$work/Info.plist"
cp "$REPO_ROOT/Info.plist" "$plist"
bash "$SCRIPT" "$plist" >/dev/null
check "bundle id" "$(value CFBundleIdentifier "$plist")" "dev.surranov.transcripted"
check "bundle name" "$(value CFBundleName "$plist")" "Transcripted Dev"
check "display name" "$(value CFBundleDisplayName "$plist")" "Transcripted Dev"
check "support folder" "$(value TranscriptedAppSupportFolderName "$plist")" "Transcripted Dev"
for key in SUFeedURL TranscriptedSentryDSN TranscriptedPostHogAPIKey TranscriptedPostHogHost; do
    check "$key removed" "$(value "$key" "$plist")" "<missing>"
done
check "version kept" "$(value CFBundleShortVersionString "$plist")" "$(value CFBundleShortVersionString "$REPO_ROOT/Info.plist")"

# Running it twice is harmless (build.sh reruns on every build).
bash "$SCRIPT" "$plist" >/dev/null
check "idempotent bundle id" "$(value CFBundleIdentifier "$plist")" "dev.surranov.transcripted"

refused() {
    local label="$1"; shift
    cp "$REPO_ROOT/Info.plist" "$work/refuse.plist"
    if env "$@" bash "$SCRIPT" "$work/refuse.plist" >/dev/null 2>&1; then
        check "$label refused" "accepted" "refused"
    else
        check "$label refused" "refused" "refused"
        check "$label leaves plist untouched" "$(value CFBundleIdentifier "$work/refuse.plist")" "com.justinbetker.draft"
    fi
}
refused "official id prefix" TRANSCRIPTED_DEV_BUNDLE_ID=com.justinbetker.draft.dev
refused "official folder" TRANSCRIPTED_DEV_SUPPORT_FOLDER=Transcripted
refused "nested folder" TRANSCRIPTED_DEV_SUPPORT_FOLDER=a/b
refused "parent folder" TRANSCRIPTED_DEV_SUPPORT_FOLDER=..

if [ "$failures" -gt 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "all dev-variant-plist checks passed"
