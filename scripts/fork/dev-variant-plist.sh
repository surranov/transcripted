#!/bin/bash
# Turns a freshly built bundle's Info.plist into the fork's "Transcripted Dev"
# variant, which runs beside the official Transcripted without sharing state:
#   - own bundle id: own UserDefaults domain, TCC grants, login item, Writing suite
#   - own Application Support folder (TranscriptedAppSupportFolder and its copies
#     in CoreStoragePaths and DiagnosticsLog read TranscriptedAppSupportFolderName)
#   - no Sparkle feed: Sparkle never starts, so an official update can't replace it
#   - no Sentry/PostHog keys: nothing is reported to the upstream owner's projects
# build.sh calls it through TRANSCRIPTED_PLIST_OVERRIDES; see build-dev.sh.
#
# Usage: dev-variant-plist.sh <path/to/Info.plist>
set -euo pipefail

plist="${1:?usage: dev-variant-plist.sh <Info.plist>}"
bundle_id="${TRANSCRIPTED_DEV_BUNDLE_ID:-dev.surranov.transcripted}"
display_name="${TRANSCRIPTED_DEV_DISPLAY_NAME:-Transcripted Dev}"
support_folder="${TRANSCRIPTED_DEV_SUPPORT_FOLDER:-Transcripted Dev}"

# An id under the official prefix would land back in official domains
# (e.g. the Writing suite is "<bundle id>.writing").
case "$bundle_id" in
    com.justinbetker.draft*)
        echo "dev-variant-plist: refusing a bundle id under com.justinbetker.draft" >&2
        exit 1
        ;;
esac
# The app falls back to "Transcripted" (official data) for anything that isn't
# one new path component, so reject those here instead of shipping them.
case "$support_folder" in
    "" | Transcripted | */* | . | ..)
        echo "dev-variant-plist: support folder must be one path component other than Transcripted" >&2
        exit 1
        ;;
esac

plutil -replace CFBundleIdentifier -string "$bundle_id" "$plist"
plutil -replace CFBundleName -string "$display_name" "$plist"
plutil -replace CFBundleDisplayName -string "$display_name" "$plist"
plutil -replace TranscriptedAppSupportFolderName -string "$support_folder" "$plist"

for key in SUFeedURL TranscriptedSentryDSN TranscriptedPostHogAPIKey TranscriptedPostHogHost; do
    if plutil -extract "$key" raw "$plist" >/dev/null 2>&1; then
        plutil -remove "$key" "$plist"
    fi
done

echo "Dev variant Info.plist: $bundle_id, \"$display_name\", Application Support/$support_folder"
