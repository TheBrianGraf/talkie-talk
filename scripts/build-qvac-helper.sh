#!/bin/sh
# Build the Metal-enabled QVAC Parakeet helper and copy it where Tauri
# expects an external binary (src-tauri/binaries/talkie-qvac-<triple>).
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SPEECH="$ROOT/third_party/qvac-fabric-speech.cpp"
GGML="$SPEECH/ggml-src"
PREFIX_GGML="$SPEECH/ggml-install"
PREFIX_SPEECH="$SPEECH/speech-install"
HELPER_BUILD="$ROOT/third_party/talkie-qvac-build"
DEST="$ROOT/src-tauri/binaries/talkie-qvac-aarch64-apple-darwin"

if [ ! -d "$GGML/.git" ]; then
    echo "missing $GGML; clone qvac-ext-ggml --branch speech there first" >&2
    exit 1
fi

cmake -S "$GGML" -B "$GGML/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_OPENMP=OFF \
    -DGGML_LLAMAFILE=ON \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_GGML"
cmake --build "$GGML/build" --parallel
cmake --install "$GGML/build"

cmake -S "$SPEECH" -B "$SPEECH/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_PREFIX_PATH="$PREFIX_GGML" \
    -DCMAKE_INSTALL_PREFIX="$PREFIX_SPEECH" \
    -DSPEECH_BUILD_WHISPER=OFF \
    -DSPEECH_BUILD_TTS=OFF \
    -DSPEECH_BUILD_AUDIOGEN=OFF \
    -DSPEECH_BUILD_TESTS=OFF \
    -DSPEECH_BUILD_EXECUTABLES=OFF
cmake --build "$SPEECH/build" --parallel --target qvac-parakeet
cmake --install "$SPEECH/build"

cmake -S "$ROOT/src-tauri/qvac-helper" -B "$HELPER_BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_PREFIX_PATH="$PREFIX_SPEECH;$PREFIX_GGML"
cmake --build "$HELPER_BUILD" --parallel

mkdir -p "$ROOT/src-tauri/binaries"
cp "$HELPER_BUILD/talkie-qvac" "$DEST"
chmod +x "$DEST"
echo "helper: $DEST"
