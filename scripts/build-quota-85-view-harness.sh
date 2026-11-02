#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
REV="$ROOT/build/independent-quota-window/revisions/task85-view-c2"
APP="$REV/candidates/Quota85Acceptance.app"
[[ ! -e "$REV" ]] || { echo "Refusing to overwrite $REV" >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$REV/module-cache"
SOURCES=("$ROOT/Sources/QuotaWindowLayout.swift" "$ROOT/Sources/QuotaCountdown.swift" "$ROOT/Sources/QuotaRealData.swift" "$ROOT/Sources/QuotaRealProvider.swift" "$ROOT/Sources/QuotaRealModel.swift" "$ROOT/Sources/OverlayRuntimePaths.swift" "$ROOT/Sources/OverlayTerminationSignal.swift" "$ROOT/Sources/QuotaWindowReal.swift" "$ROOT/validation/Quota85ViewHarness.swift")
shasum -a 256 "${SOURCES[@]}" > "$REV/build-inputs.txt"
xcrun swiftc -D QUOTA_TESTING -parse-as-library -module-cache-path "$REV/module-cache" -target arm64-apple-macosx14.0 -framework AppKit -framework SwiftUI -framework CoreGraphics "${SOURCES[@]}" -o "$APP/Contents/MacOS/Quota85Acceptance" > "$REV/swiftc.log" 2>&1
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Quota85Acceptance</string>
<key>CFBundleIdentifier</key><string>local.msl.QuotaWindow.Acceptance85</string>
<key>CFBundleName</key><string>额度验收测试</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>85-c1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>OverlayRuntimeDirectoryName</key><string>runtime</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" > "$REV/codesign.log" 2>&1
codesign --verify --deep --strict --verbose=2 "$APP" >> "$REV/codesign.log" 2>&1
shasum -a 256 "$APP/Contents/MacOS/Quota85Acceptance" > "$REV/executable.sha256"
echo "built=$APP"
