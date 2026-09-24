#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build/'클릭 녹화기.app'/Contents/MacOS
APP="$PWD/build/클릭 녹화기.app"
swiftc -O -swift-version 5 -module-name ClickRecorder Sources/Model.swift Sources/App.swift -o "$APP/Contents/MacOS/ClickRecorder" -framework AppKit -framework Carbon -framework CoreGraphics
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.tei.ClickRecorder</string>
<key>CFBundleName</key><string>클릭 녹화기</string>
<key>CFBundleExecutable</key><string>ClickRecorder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSInputMonitoringUsageDescription</key><string>다른 앱에서 클릭한 좌표와 키보드 입력 및 시간을 녹화합니다.</string>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.tei.ClickRecorder "$APP"
echo "완료: $APP"
