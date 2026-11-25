#!/usr/bin/env bash
# Build Talkie-Talk for Apple Silicon: the QVAC helper, the model bundled
# inside the app, and the .app + .dmg under src-tauri/target.
#
#   ./scripts/build-mac.sh
#
# Then ./scripts/install-mac.sh copies the app into /Applications.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "Talkie-Talk builds on an Apple Silicon Mac." >&2
  exit 1
fi
for tool in bun cargo cmake git curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

MODELS="$ROOT/src-tauri/resources/models"
QVAC_REPO="qvac/TranscribePsy-250M-EU-sub-gguf"
QVAC_FILE="transcribepsy-250m-eu-sub.gguf"
VAD_FILE="silero-vad-v6.2-F32.gguf"
mkdir -p "$MODELS"

# 1. The on-device engine (Metal-enabled QVAC Parakeet helper).
if [[ ! -x "$ROOT/src-tauri/binaries/talkie-qvac-aarch64-apple-darwin" ]]; then
  echo "==> Building the QVAC helper"
  sh "$ROOT/scripts/build-qvac-helper.sh"
fi

# 2. Models shipped inside the app, so the first launch works offline.
if [[ ! -f "$MODELS/$VAD_FILE" ]]; then
  echo "==> Fetching the voice-activity model"
  curl -fL -o "$MODELS/$VAD_FILE" \
    "https://huggingface.co/handy-computer/silero-vad-v6.2-gguf/resolve/main/$VAD_FILE"
fi
if [[ ! -f "$MODELS/$QVAC_FILE" ]]; then
  CACHED=$(find "$HOME/.cache/huggingface/hub/models--${QVAC_REPO//\//--}/snapshots" -name "$QVAC_FILE" -print -quit 2>/dev/null || true)
  if [[ -n "$CACHED" ]]; then
    echo "==> Using the cached QVAC model"
    cp -L "$CACHED" "$MODELS/$QVAC_FILE"
  else
    echo "==> Downloading the QVAC model (about 300 MB, one time)"
    curl -fL -o "$MODELS/$QVAC_FILE" \
      "https://huggingface.co/$QVAC_REPO/resolve/main/$QVAC_FILE"
  fi
fi

# 3. App bundle and disk image.
echo "==> Installing JavaScript dependencies"
bun install --frozen-lockfile
echo "==> Building Talkie-Talk"
CMAKE_POLICY_VERSION_MINIMUM=3.5 bun run tauri build --target aarch64-apple-darwin --bundles app,dmg

BUNDLE="$ROOT/src-tauri/target/aarch64-apple-darwin/release/bundle"
echo
echo "Built:"
ls -d "$BUNDLE"/macos/*.app "$BUNDLE"/dmg/*.dmg
echo
echo "Install with: ./scripts/install-mac.sh"
