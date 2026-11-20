#!/usr/bin/env bash
# Install Brian's fast transcription on an Apple Silicon Mac.
#
# From a folder that contains the .dmg (for example a GitHub release download):
#   chmod +x install-mac.sh
#   ./install-mac.sh
#
# Or point it at the disk image or app bundle:
#   ./install-mac.sh "/path/to/Brian's fast transcription_0.10.1_aarch64.dmg"
#
# With the GitHub CLI signed in and access to the private repo, no arguments
# downloads the latest release and installs it.
#
# INSTALL_DIR overrides the destination directory (default: /Applications when
# writable, otherwise ~/Applications).

set -euo pipefail

APP_NAME="Brian's fast transcription"
REPO="TheBrianGraf/brians-fast-transcription"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS." >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "This build runs on Apple Silicon (M1 or later). This Mac is $(uname -m)." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MOUNT=""

cleanup() {
  if [[ -n "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -quiet || true
    MOUNT=""
  fi
}
trap cleanup EXIT

find_dmg_in() {
  local dir="$1"
  find "$dir" -maxdepth 1 -name '*.dmg' -print -quit 2>/dev/null || true
}

download_release() {
  local dest="$1"
  if ! command -v gh >/dev/null 2>&1; then
    echo "No disk image found, and the GitHub CLI is not installed." >&2
    echo "Download the .dmg from the repo's Releases page and run this script again in that folder." >&2
    exit 1
  fi
  echo "Downloading the latest release from ${REPO}..."
  gh release download --repo "$REPO" --pattern '*.dmg' --dir "$dest" --clobber
  local dmg
  dmg=$(find_dmg_in "$dest")
  if [[ -z "$dmg" ]]; then
    echo "The release has no .dmg asset." >&2
    exit 1
  fi
  echo "$dmg"
}

resolve_source() {
  if [[ $# -ge 1 ]]; then
    if [[ ! -e "$1" ]]; then
      echo "Not found: $1" >&2
      exit 1
    fi
    echo "$1"
    return
  fi

  local beside
  beside=$(find_dmg_in "$SCRIPT_DIR")
  if [[ -n "$beside" ]]; then
    echo "$beside"
    return
  fi

  local repo_root="$SCRIPT_DIR/.."
  local built=""
  if [[ -d "$repo_root/src-tauri/target/release/bundle/dmg" ]]; then
    built=$(find_dmg_in "$repo_root/src-tauri/target/release/bundle/dmg")
  fi
  if [[ -n "$built" ]]; then
    echo "$built"
    return
  fi

  local tmp
  tmp=$(mktemp -d)
  download_release "$tmp"
}

SOURCE=$(resolve_source "$@")
APP_SRC=""

case "$SOURCE" in
  *.dmg)
    echo "Opening $SOURCE"
    PLIST=$(mktemp)
    diskutil image attach --plist --readOnly --nobrowse "$SOURCE" >"$PLIST"
    MOUNT=$(python3 - "$PLIST" <<'PY'
import plistlib
import sys
with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)
for entry in data.get("system-entities", []):
    point = entry.get("mount-point")
    if point:
        print(point)
        break
PY
)
    rm -f "$PLIST"
    if [[ -z "$MOUNT" ]]; then
      echo "Could not mount $SOURCE" >&2
      exit 1
    fi
    APP_SRC=$(find "$MOUNT" -maxdepth 2 -name '*.app' -print -quit)
    ;;
  *.app)
    APP_SRC=$SOURCE
    ;;
  *)
    echo "Expected a .dmg or a .app, got: $SOURCE" >&2
    exit 1
    ;;
esac

if [[ -z "$APP_SRC" || ! -d "$APP_SRC" ]]; then
  echo "No app bundle found in $SOURCE" >&2
  exit 1
fi

echo "Quitting any running copy..."
osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
osascript -e 'tell application "Handy" to quit' >/dev/null 2>&1 || true
pkill -x handy >/dev/null 2>&1 || true
sleep 1

if [[ -n "${INSTALL_DIR:-}" ]]; then
  mkdir -p "$INSTALL_DIR"
  DEST="${INSTALL_DIR%/}/${APP_NAME}.app"
elif [[ -w /Applications ]]; then
  DEST="/Applications/${APP_NAME}.app"
else
  mkdir -p "${HOME}/Applications"
  DEST="${HOME}/Applications/${APP_NAME}.app"
  echo "/Applications is not writable, so this installs for your user only."
fi

if [[ -d "$DEST" ]]; then
  rm -rf "${DEST}.previous"
  mv "$DEST" "${DEST}.previous"
  echo "Kept the previous copy at ${DEST}.previous"
fi

echo "Installing to $DEST"
ditto "$APP_SRC" "$DEST"
xattr -dr com.apple.quarantine "$DEST" || true

cleanup

echo
echo "Installed ${APP_NAME}."
echo "The first dictation may ask for Microphone, Accessibility, and Input Monitoring."
if [[ -d "/Applications/Handy.app" || -d "${HOME}/Applications/Handy.app" ]]; then
  echo "An older Handy.app is still installed. Quit it so the two apps don't share a shortcut."
fi

open "$DEST"
