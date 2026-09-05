#!/bin/zsh
# Build a Release copy of Notchy and install it into /Applications.
#
# Usage: scripts/install.sh [--no-launch]
#
# Builds into .build.noindex/ inside the repo. The ".noindex" suffix keeps
# Spotlight from listing the intermediate app bundle, so the only "Notchy"
# Spotlight ever shows is the installed one.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_DIR/.build.noindex"
APP_NAME="Notchy"
INSTALL_PATH="/Applications/$APP_NAME.app"
LAUNCH=1
[[ "${1:-}" == "--no-launch" ]] && LAUNCH=0

cd "$REPO_DIR"

echo "==> Building $APP_NAME (Release)"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    build 2>&1 | grep -E "error:|warning: .*$APP_NAME/|BUILD" || true

BUILT_APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Build failed: $BUILT_APP not found" >&2
    exit 1
fi

if pgrep -xq "$APP_NAME"; then
    echo "==> Quitting running $APP_NAME"
    osascript -e "tell application \"$APP_NAME\" to quit" || true
    for _ in {1..20}; do
        pgrep -xq "$APP_NAME" || break
        sleep 0.25
    done
    if pgrep -xq "$APP_NAME"; then
        echo "    still running, sending SIGTERM"
        pkill -x "$APP_NAME" || true
        sleep 1
    fi
fi

echo "==> Installing to $INSTALL_PATH"
rm -rf "$INSTALL_PATH"
ditto "$BUILT_APP" "$INSTALL_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INSTALL_PATH/Contents/Info.plist")"
COMMIT="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "    installed $APP_NAME $VERSION (commit $COMMIT)"

if (( LAUNCH )); then
    echo "==> Launching"
    # `open` forwards this shell's environment to the app. When this script runs
    # from inside a Claude Code session, that would hand CLAUDE_* session markers
    # to Notchy and on to every terminal it spawns. Launch with those removed.
    UNSET_ARGS=()
    for var in ${(k)parameters}; do
        [[ "$var" == CLAUDE* ]] && UNSET_ARGS+=(-u "$var")
    done
    env "${UNSET_ARGS[@]}" open "$INSTALL_PATH"
fi
