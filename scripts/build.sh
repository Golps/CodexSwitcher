#!/bin/bash
# Compiles Codex Switcher into build/Codex Switcher.app (Apple Silicon only).
# With --dmg it also makes build/CodexSwitcher.dmg for distribution.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/Codex Switcher.app"
cd "$ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p work/module-cache

xcrun swiftc \
    -O \
    -parse-as-library \
    -target arm64-apple-macos13.0 \
    -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -module-cache-path work/module-cache \
    -file-prefix-map "$ROOT"=. \
    -debug-prefix-map "$ROOT"=. \
    -o "$APP/Contents/MacOS/CodexSwitcher" \
    Sources/*.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SIGN_IDENTITY selects the maintained release certificate. Local builds default
# to ad-hoc signing. macOS can still request Keychain access after an update.
SIGN_ARGS=(--force --sign "${SIGN_IDENTITY:--}")
if [ -n "${SIGN_KEYCHAIN:-}" ]; then SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN"); fi
codesign "${SIGN_ARGS[@]}" "$APP" >/dev/null

# Disk image with the usual drag-to-Applications layout.
if [ "${1:-}" = "--dmg" ]; then
    STAGE="$ROOT/build/dmg"
    rm -rf "$STAGE" "$ROOT/build/CodexSwitcher.dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Codex Switcher" -srcfolder "$STAGE" -fs HFS+ -format UDZO \
        "$ROOT/build/CodexSwitcher.dmg" >/dev/null
    rm -rf "$STAGE"
    echo "Built: $ROOT/build/CodexSwitcher.dmg"
fi

echo "Built: $APP"
