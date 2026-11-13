#!/usr/bin/env bash
# Build comux (the offline fork of cmux) for Apple silicon.
#
#   comux/build.sh              build Release and ad-hoc sign it
#   comux/build.sh --install    also copy the result to ~/Applications/comux.app
#   comux/build.sh --debug      build the Debug configuration instead
#
# Requirements: Xcode. No zig, cargo or bun.
#
# Network use (build time only, both cached after the first run):
#   - GhosttyKit.xcframework, a prebuilt archive from GitHub Releases,
#     cached in ~/.cache/cmux/ghosttykit and verified by sha256.
#   - Six Swift package dependencies that Xcode fetches from GitHub into
#     $COMUX_DERIVED_DATA/SourcePackages.
#
# Environment:
#   COMUX_DERIVED_DATA   build directory (default: ~/Library/Caches/comux-build)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="${COMUX_DERIVED_DATA:-$HOME/Library/Caches/comux-build}"
CONFIGURATION=Release
INSTALL=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --debug) CONFIGURATION=Debug ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown option $arg" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "error: comux builds for Apple silicon only." >&2
  exit 1
fi

cd "$REPO"

if [[ ! -f ghostty/include/ghostty.h || ! -f vendor/bonsplit/Package.swift ]]; then
  echo "==> Initializing submodules"
  git submodule update --init ghostty vendor/bonsplit
fi

if [[ ! -e GhosttyKit.xcframework ]]; then
  echo "==> Fetching the prebuilt GhosttyKit.xcframework"
  # ensure-ghosttykit.sh insists on finding zig even when it only downloads
  # the prebuilt archive, so give it a stub that can never build anything.
  STUB_DIR="$(mktemp -d)"
  trap 'rm -rf "$STUB_DIR"' EXIT
  printf '#!/bin/sh\necho "zig stub: source builds are not supported" >&2\nexit 1\n' > "$STUB_DIR/zig"
  chmod +x "$STUB_DIR/zig"
  PATH="$STUB_DIR:$PATH" scripts/ensure-ghosttykit.sh
fi

LOG="$DERIVED/build.log"
mkdir -p "$DERIVED"
echo "==> Building $CONFIGURATION (log: $LOG)"
if ! CMUX_SKIP_ZIG_BUILD=1 xcodebuild \
  -project cmux.xcodeproj -scheme cmux -configuration "$CONFIGURATION" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" \
  -skipPackagePluginValidation -skipMacroValidation build > "$LOG" 2>&1; then
  echo "error: build failed" >&2
  grep -E ": error: |^error: " "$LOG" | sort -u | head -40 >&2 || true
  exit 1
fi

if [[ "$CONFIGURATION" == "Release" ]]; then
  APP="$DERIVED/Build/Products/Release/comux.app"
else
  APP="$DERIVED/Build/Products/Debug/cmux DEV.app"
fi

echo "==> Ad-hoc signing"
codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"

if [[ "$INSTALL" == "1" ]]; then
  if [[ "$CONFIGURATION" != "Release" ]]; then
    echo "error: --install only applies to the Release build." >&2
    exit 1
  fi
  DEST="$HOME/Applications/comux.app"
  if pgrep -f "$DEST/Contents/MacOS/comux" >/dev/null 2>&1; then
    echo "error: comux is running. Quit it, then run this again." >&2
    exit 1
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed: $DEST"
fi
