#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mkdir -p work/screenshots assets/screenshots
# Reuse the real UI without compiling the production application entry point or
# any credential, account-storage, sign-in, or networking implementation.
python3 - <<'PY'
from pathlib import Path
source = Path('Sources/CodexSwitcherApp.swift').read_text()
Path('work/screenshots/MenuViews.swift').write_text(
    'import AppKit\nimport SwiftUI\n\n' + source[source.index('struct MenuView: View'):])
usage = Path('Sources/Usage.swift').read_text()
Path('work/screenshots/UsageTypes.swift').write_text(usage[:usage.index('/// Reads usage')])
PY
xcrun swiftc -O -parse-as-library -target arm64-apple-macos13.0 \
    -sdk "${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}" \
    -module-cache-path work/module-cache \
    -file-prefix-map "$ROOT"=. -debug-prefix-map "$ROOT"=. \
    -o work/screenshots/render-menu \
    Sources/SettingsFooter.swift Sources/StatusPanelWindow.swift \
    work/screenshots/MenuViews.swift work/screenshots/UsageTypes.swift Tests/ScreenshotFixture.swift
SWITCHER_DEMO_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)" \
    work/screenshots/render-menu assets/screenshots
