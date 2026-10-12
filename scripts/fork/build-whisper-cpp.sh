#!/bin/bash
# Build whisper.cpp as one static archive plus a Clang module, for the fork's
# Breeze dictation engine (Sources/Speech/WhisperCppTranscriber.swift):
#   deps-whisper-cpp/libWhisperCpp.a     whisper + ggml (CPU, Metal with the
#                                        shader library embedded, BLAS) + the
#                                        Core ML encoder
#   deps-whisper-cpp/WhisperCpp/         module.modulemap + whisper.h and the
#                                        ggml headers it includes
#   deps-whisper-cpp/.stamp              the pinned revision; a rerun is a no-op
# Its own folder, not deps-libs/deps-modules, because build-deps.sh replaces
# those wholesale. The app build links the archive only when it exists, and
# the engine compiles only when the module is importable, so a checkout
# without it still builds (Breeze then shows as not built).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

WHISPER_CPP_VERSION="${WHISPER_CPP_VERSION:-v1.9.5}"
WHISPER_CPP_REVISION="${WHISPER_CPP_REVISION:-d1be6fde11ac6e0407606b4e42fe72d34add8037}"
OUT="$ROOT/deps-whisper-cpp"
LIB="$OUT/libWhisperCpp.a"
MODULE_DIR="$OUT/WhisperCpp"
STAMP="$OUT/.stamp"

if [ "${1:-}" != "--force" ] && [ -f "$LIB" ] && [ -f "$MODULE_DIR/module.modulemap" ] \
    && [ "$(cat "$STAMP" 2>/dev/null)" = "$WHISPER_CPP_REVISION" ]; then
    echo "whisper.cpp $WHISPER_CPP_VERSION already built ($LIB)"
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-whisper-cpp.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching whisper.cpp $WHISPER_CPP_VERSION..."
git clone -q --depth 1 --branch "$WHISPER_CPP_VERSION" https://github.com/ggml-org/whisper.cpp "$WORK/src"
actual="$(git -C "$WORK/src" rev-parse HEAD)"
if [ "$actual" != "$WHISPER_CPP_REVISION" ]; then
    echo "[build-whisper-cpp] ERROR: $WHISPER_CPP_VERSION is $actual, expected $WHISPER_CPP_REVISION" >&2
    exit 1
fi

# Static, arm64, macOS 26 like the app. Core ML runs the encoder on the Neural
# Engine; ALLOW_FALLBACK lets a model without a Core ML encoder (or one that
# fails to load) fall back to the Metal encoder instead of failing.
cmake -S "$WORK/src" -B "$WORK/build" -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON \
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF \
    > "$WORK/cmake.log" 2>&1 || { tail -30 "$WORK/cmake.log" >&2; exit 1; }
cmake --build "$WORK/build" --config Release -j "$(sysctl -n hw.ncpu)" > "$WORK/build.log" 2>&1 \
    || { tail -40 "$WORK/build.log" >&2; exit 1; }

archives=()
while IFS= read -r -d '' archive; do archives+=("$archive"); done \
    < <(find "$WORK/build" -name '*.a' -print0)
if [ "${#archives[@]}" -eq 0 ]; then
    echo "[build-whisper-cpp] ERROR: no static archives built" >&2
    exit 1
fi

mkdir -p "$OUT"
rm -f "$LIB.tmp"
libtool -static -no_warning_for_no_symbols -o "$LIB.tmp" "${archives[@]}"
# One nm pass into a variable: `nm | grep -q` under pipefail fails on SIGPIPE.
symbols="$(nm -g "$LIB.tmp" 2>/dev/null || true)"
for symbol in _whisper_init_from_file_with_params _whisper_full _ggml_backend_metal_init; do
    if ! grep -q " T $symbol\$" <<< "$symbols"; then
        echo "[build-whisper-cpp] ERROR: $symbol missing from the merged archive" >&2
        exit 1
    fi
done
mv -f "$LIB.tmp" "$LIB"

rm -rf "$MODULE_DIR.tmp"
mkdir -p "$MODULE_DIR.tmp"
cp "$WORK/src/include/whisper.h" "$WORK/src/ggml/include/"*.h "$MODULE_DIR.tmp/"
cat > "$MODULE_DIR.tmp/module.modulemap" <<'MODULEMAP'
module WhisperCpp {
    header "whisper.h"
    export *
    link "c++"
}
MODULEMAP
rm -rf "$MODULE_DIR"
mv "$MODULE_DIR.tmp" "$MODULE_DIR"

echo "$WHISPER_CPP_REVISION" > "$STAMP"
echo "Built whisper.cpp $WHISPER_CPP_VERSION: $LIB ($(du -h "$LIB" | cut -f1)), module $MODULE_DIR"
