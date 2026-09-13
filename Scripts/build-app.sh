#!/bin/bash
# 组装 LivePhotoForge.app。
# 不需要完整 Xcode：SwiftPM 编译可执行文件，这里手工装 bundle 再 ad-hoc 签名。
# 签名是必需的——TCC 靠它记住照片图库授权，换了签名就要重新授权。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/LivePhotoForge.app"

cd "$ROOT"
swift build -c "$CONFIG" --product LivePhotoForgeApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/$CONFIG/LivePhotoForgeApp" "$APP/Contents/MacOS/LivePhotoForgeApp"
cp "$ROOT/Resources/LivePhotoForge-Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP" 2>&1 | tail -2

echo "已生成 $APP"
