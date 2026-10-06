#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
APP="$PWD/MouseWinCurve.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 Sources/*.swift -o "$APP/Contents/MacOS/MouseWinCurve" -framework AppKit -framework SwiftUI -framework IOKit -framework ApplicationServices -framework ServiceManagement -framework Carbon -module-cache-path ../../work/swift-cache
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MouseWinCurve</string>
<key>CFBundleIdentifier</key><string>local.mouselockcurve.app</string>
<key>CFBundleName</key><string>MouseWinCurve</string>
<key>CFBundleDisplayName</key><string>MouseWinCurve</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>17</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><false/>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSInputMonitoringUsageDescription</key><string>마우스 원시 이동량을 읽어 사용자 지정 가속 곡선을 적용합니다.</string>
</dict></plist>
PLIST
cp Assets/AppIcon.icns Assets/MenuIcon.png "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built: $APP"
