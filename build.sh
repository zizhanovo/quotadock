#!/bin/bash
# QuotaDock 构建/安装脚本
#   ./build.sh            仅编译
#   ./build.sh --install  编译 + 安装 launchd 开机自启（local.quotadock）
set -e
cd "$(dirname "$0")"

APP=QuotaDock.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -o "$APP/Contents/MacOS/QuotaDock" main.swift
rm -rf "$APP/Contents/Resources/logos"
cp -R logos "$APP/Contents/Resources/logos"
echo "built $APP"

if [ "$1" = "--install" ]; then
    PLIST=~/Library/LaunchAgents/local.quotadock.plist
    sed "s#__BIN__#$PWD/$APP/Contents/MacOS/QuotaDock#" launchd.plist.template > "$PLIST"
    launchctl bootout gui/$(id -u)/local.quotadock 2>/dev/null || true
    launchctl bootstrap gui/$(id -u) "$PLIST"
    echo "installed launchd agent: local.quotadock（日志 /tmp/quotadock.out.log）"
fi
