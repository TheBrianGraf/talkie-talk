#!/usr/bin/env bash
# Install Talkie-Talk into /Applications on an Apple Silicon Mac.
#
#   curl -fsSL https://raw.githubusercontent.com/TheBrianGraf/talkie-talk/talkie-talk/scripts/install-mac.sh | bash
#                                            # download the latest release and install it
#   ./scripts/install-mac.sh                 # use a build in this checkout, else download the latest release
#   ./scripts/install-mac.sh path/to/Talkie-Talk.dmg   # or a .dmg / .app you were given
#
# INSTALL_DIR overrides the destination (default: /Applications, or
# ~/Applications when /Applications is not writable).

set -euo pipefail

APP_NAME="Talkie-Talk"
REPO="TheBrianGraf/talkie-talk"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer is for macOS." >&2
  exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  echo "Talkie-Talk runs on Apple Silicon (M1 or later). This Mac is $(uname -m)." >&2
  exit 1
fi

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")
REPO_ROOT="$SCRIPT_DIR/.."
BUNDLE="$REPO_ROOT/src-tauri/target/aarch64-apple-darwin/release/bundle"
MOUNT=""
WORK=""

cleanup() {
  [[ -n "$WORK" ]] && rm -rf "$WORK"
  if [[ -n "$MOUNT" ]]; then
    hdiutil detach "$MOUNT" -quiet || true
    MOUNT=""
  fi
}
trap cleanup EXIT

find_first() { # dir pattern
  find "$1" -maxdepth 1 -name "$2" -print -quit 2>/dev/null || true
}

download_latest() {
  WORK=$(mktemp -d)
  echo "Finding the latest Talkie-Talk release..." >&2
  local url
  url=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
    | grep -o '"browser_download_url": *"[^"]*\.dmg"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')
  [[ -n "$url" ]] || { echo "Could not find a .dmg in the latest release of ${REPO}." >&2; exit 1; }
  echo "Downloading ${url##*/} (about 300 MB)..." >&2
  curl -fL --progress-bar -o "$WORK/${url##*/}" "$url" >&2
  echo "$WORK/${url##*/}"
}

resolve_source() {
  if [[ $# -ge 1 ]]; then
    [[ -e "$1" ]] || { echo "Not found: $1" >&2; exit 1; }
    echo "$1"
    return
  fi
  local found=""
  if [[ -n "$SCRIPT_DIR" ]]; then
    found=$(find_first "$SCRIPT_DIR" '*.dmg')
    [[ -z "$found" ]] && found=$(find_first "$BUNDLE/macos" '*.app')
    [[ -z "$found" ]] && found=$(find_first "$BUNDLE/dmg" '*.dmg')
  fi
  [[ -z "$found" ]] && found=$(download_latest)
  echo "$found"
}

SOURCE=$(resolve_source "$@")
APP_SRC=""

case "$SOURCE" in
  *.dmg)
    echo "Opening $SOURCE"
    MOUNT=$(hdiutil attach -nobrowse -readonly "$SOURCE" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
    [[ -n "$MOUNT" ]] || { echo "Could not mount $SOURCE" >&2; exit 1; }
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
[[ -n "$APP_SRC" && -d "$APP_SRC" ]] || { echo "No app bundle found in $SOURCE" >&2; exit 1; }

echo "Quitting any running copy..."
osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
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
# The app is ad-hoc signed locally; clear the download quarantine so it opens.
xattr -dr com.apple.quarantine "$DEST" || true
cleanup

echo
echo "Installed ${APP_NAME}."
echo "The first dictation asks for Microphone, Accessibility and Input Monitoring."
open "$DEST"
