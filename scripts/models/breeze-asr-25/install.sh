#!/usr/bin/env bash
# Install Breeze-ASR-25 for Transcripted's whisper.cpp engine (fork).
#
#   bash scripts/models/breeze-asr-25/install.sh                       # Transcripted
#   bash scripts/models/breeze-asr-25/install.sh --app "Transcripted Dev"
#   bash scripts/models/breeze-asr-25/install.sh --from DIR            # copy, don't download
#
# Breeze-ASR-25 is MediaTek Research's Whisper large-v2 fine-tune for speech
# that switches languages (Apache-2.0). This fetches a whisper.cpp build of it
# (q8 weights, ~1.6 GB, plus a Core ML encoder, ~1.3 GB) at a pinned
# revision, checks every file's SHA-256, and installs it atomically under
# ~/Library/Application Support/<app>/models/breeze-asr-25. The marker file
# is written last; the app ignores a folder without it. Afterwards "Breeze ASR
# 25 (Experimental)" appears in Settings > General > Model.
set -euo pipefail

REPO="shdennlin/breeze-asr-25-ggml"
REVISION="36c726093efe1760d1dd39c3cfe8b6a7282437d1"
# path<TAB>sha256, from the Hugging Face file listing at REVISION.
FILES="ggml-breeze-asr-25-q8_0.bin	d4b187c40ffbf1f620734b77821e2ca8a97c8ecf5754d02b2a175069348cafcf
ggml-breeze-asr-25-encoder.mlmodelc/coremldata.bin	54d16c90e16dd9661b19d0cdc2b2fcd729073463e13053fac4412441a86fb420
ggml-breeze-asr-25-encoder.mlmodelc/analytics/coremldata.bin	0675cbfc7d613d7eba54aa1cca0d715ebfddc9cf48c74b44cbf9044638118af9
ggml-breeze-asr-25-encoder.mlmodelc/metadata.json	52bbbefc02bddf8318c4bb38c7fd3269309f018b64ebb7ea54dba14d29b504a2
ggml-breeze-asr-25-encoder.mlmodelc/model.mil	eda3651358ae5db20494a32c53c6baec7cb47b496f0b59d5c048ffcd44b4336c
ggml-breeze-asr-25-encoder.mlmodelc/weights/weight.bin	6681b327294d396c953b1fd1e232dcf9deb246ac16539891e093e0556a8b9f15"

APP_FOLDER="Transcripted"
FROM_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_FOLDER="$2"; shift 2 ;;
        --from) FROM_DIR="$2"; shift 2 ;;
        *) echo "usage: $0 [--app \"Transcripted Dev\"] [--from DIR]" >&2; exit 2 ;;
    esac
done

fail() { echo "error: $*" >&2; exit 1; }

INSTALL_ROOT="${BREEZE_INSTALL_ROOT:-$HOME/Library/Application Support/$APP_FOLDER/models}"
FINAL="$INSTALL_ROOT/breeze-asr-25"
STAGING="$INSTALL_ROOT/.breeze-asr-25.partial"
# Only ever delete inside the models folder this script owns.
case "$STAGING" in "$INSTALL_ROOT"/*) ;; *) fail "unexpected staging path";; esac

mkdir -p "$INSTALL_ROOT"
rm -rf "$STAGING"
mkdir -p "$STAGING"
trap 'rm -rf "$STAGING"' EXIT

while IFS=$'\t' read -r path sha; do
    [[ -n "$path" ]] || continue
    target="$STAGING/$path"
    mkdir -p "$(dirname "$target")"
    if [[ -n "$FROM_DIR" ]]; then
        [[ -f "$FROM_DIR/$path" ]] || fail "$path not found in $FROM_DIR"
        # APFS clone when on the same volume: no extra disk.
        cp -c "$FROM_DIR/$path" "$target" 2>/dev/null || cp "$FROM_DIR/$path" "$target"
    else
        echo "==> Downloading $path"
        curl -fL --retry 3 --progress-bar -o "$target" \
            "https://huggingface.co/$REPO/resolve/$REVISION/$path"
    fi
    actual="$(shasum -a 256 "$target" | cut -d' ' -f1)"
    [[ "$actual" == "$sha" ]] || fail "$path checksum mismatch (got $actual)"
done <<< "$FILES"

cat > "$STAGING/transcripted-model.json" <<JSON
{
  "model": "breeze-asr-25",
  "upstream": "MediaTek-Research/Breeze-ASR-25",
  "license": "Apache-2.0",
  "source": "huggingface.co/$REPO",
  "revision": "$REVISION",
  "installed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON

# Swap in: the old install stays whole until the new one is in place.
rm -rf "$FINAL.old"
[[ -e "$FINAL" ]] && mv "$FINAL" "$FINAL.old"
mv "$STAGING" "$FINAL"
rm -rf "$FINAL.old"
trap - EXIT

echo
echo "Done. Breeze-ASR-25 is installed at:"
echo "  $FINAL"
echo "Pick \"Breeze ASR 25 (Experimental)\" in $APP_FOLDER > Settings > General > Model."
echo "The first load compiles the Core ML encoder for this Mac (up to a few minutes once)."
