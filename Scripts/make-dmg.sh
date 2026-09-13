#!/bin/bash
# 把 VideoToLive.app 打成可拖拽安装的 DMG：窗口里是 App 和「应用程序」快捷方式。
# 用法：./Scripts/make-dmg.sh   产物：dist/VideoToLive-<版本>.dmg
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

./Scripts/build-app.sh --universal

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/VideoToLive-Info.plist)
STAGING="$(mktemp -d)/VideoToLive"
DMG="$ROOT/dist/VideoToLive-$VERSION.dmg"

mkdir -p "$STAGING" "$ROOT/dist"
cp -R build/VideoToLive.app "$STAGING/"
ln -s /Applications "$STAGING/应用程序"

rm -f "$DMG"
hdiutil create -volname "VideoToLive $VERSION" -srcfolder "$STAGING" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null

echo "已生成 $DMG（$(du -h "$DMG" | cut -f1)）"
