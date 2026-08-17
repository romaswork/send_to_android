#!/bin/bash
# Собирает SendToAndroid.app. Запуск: ./build.sh   (или ./build.sh --install → в /Applications)
set -euo pipefail

cd "$(dirname "$0")"
APP="build/SendToAndroid.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>SendToAndroid</string>
    <key>CFBundleIdentifier</key><string>local.sendtoandroid</string>
    <key>CFBundleName</key><string>Send to Android</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -O Sources/main.swift -o "$APP/Contents/MacOS/SendToAndroid"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/SendToAndroid.app"
    cp -R "$APP" /Applications/
    echo "Установлено: /Applications/SendToAndroid.app"
else
    echo "Готово: $APP"
fi
