#!/bin/bash
# 组装 VideoToLive.app。
# 不需要完整 Xcode：SwiftPM 编译可执行文件，这里手工装 bundle 再 ad-hoc 签名。
# 签名是必需的——TCC 靠它记住照片图库授权，换了签名就要重新授权。
#
# 用法：
#   ./Scripts/build-app.sh              本机架构，日常开发用
#   ./Scripts/build-app.sh --universal  同时包含 Apple Silicon 与 Intel，发布用
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/VideoToLive.app"
UNIVERSAL=false
[ "${1:-}" = "--universal" ] && UNIVERSAL=true

cd "$ROOT"
if $UNIVERSAL; then
  swift build -c release --product VideoToLive --arch arm64 --arch x86_64 --build-path .build-universal
  BINARY="$ROOT/.build-universal/out/Products/Release/VideoToLive"
else
  swift build -c release --product VideoToLive
  BINARY="$ROOT/.build/release/VideoToLive"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/VideoToLive"
cp "$ROOT/Resources/VideoToLive-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" 2>&1 | tail -2

echo "已生成 $APP（$(lipo -archs "$APP/Contents/MacOS/VideoToLive")）"
