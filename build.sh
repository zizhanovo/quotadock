#!/bin/bash
# QuotaDock 构建/安装脚本（SwiftPM）
#   ./build.sh            编译 release 并组装带 Info.plist 的 app bundle
#   ./build.sh --install  编译 + 安装 launchd 开机自启（local.quotadock）
set -e
cd "$(dirname "$0")"

swift build -c release

# 版本号唯一来源：Version.swift
VERSION=$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/QuotaDock/Version.swift)
if [ -z "$VERSION" ]; then echo "error: 无法从 Version.swift 提取版本号" >&2; exit 1; fi

APP=QuotaDock.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QuotaDock "$APP/Contents/MacOS/QuotaDock"
rm -rf "$APP/Contents/Resources/logos"
cp -R logos "$APP/Contents/Resources/logos"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>QuotaDock</string>
    <key>CFBundleDisplayName</key><string>QuotaDock</string>
    <key>CFBundleIdentifier</key><string>local.quotadock.app</string>
    <key>CFBundleExecutable</key><string>QuotaDock</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

echo "built $APP (v$VERSION)"

if [ "$1" = "--install" ]; then
    PLIST=~/Library/LaunchAgents/local.quotadock.plist
    sed "s#__BIN__#$PWD/$APP/Contents/MacOS/QuotaDock#" launchd.plist.template > "$PLIST"
    launchctl bootout gui/$(id -u)/local.quotadock 2>/dev/null || true
    launchctl bootstrap gui/$(id -u) "$PLIST"
    echo "installed launchd agent: local.quotadock（日志 /tmp/quotadock.out.log）"
fi
