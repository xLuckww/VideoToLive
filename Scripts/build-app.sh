#!/bin/bash
# 组装 VideoToLive.app。
# 不需要完整 Xcode：SwiftPM 编译可执行文件，这里手工装 bundle 再 ad-hoc 签名。
# 签名是必需的——TCC 靠它记住照片图库授权，换了签名就要重新授权。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/VideoToLive.app"

cd "$ROOT"
swift build -c "$CONFIG" --product VideoToLive

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIG/VideoToLive" "$APP/Contents/MacOS/VideoToLive"
cp "$ROOT/Resources/VideoToLive-Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" 2>&1 | tail -2

echo "已生成 $APP"
