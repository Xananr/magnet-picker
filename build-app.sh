#!/bin/bash
# 打包成 MagnetPicker.app：swift build -> 组 bundle -> 生成图标 -> ad-hoc 签名
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="MagnetPicker"
BUNDLE="build/${APP_NAME}.app"

echo "==> 编译 release"
swift build -c release

echo "==> 组 bundle"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp ".build/release/${APP_NAME}" "$BUNDLE/Contents/MacOS/${APP_NAME}"
cp Info.plist "$BUNDLE/Contents/Info.plist"

if [ -f "Resources/AppIcon.png" ]; then
    echo "==> 生成图标"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 64 128 256 512; do
        sips -z $size $size "Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double "Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "==> 去符号"
strip -x "$BUNDLE/Contents/MacOS/${APP_NAME}" 2>/dev/null || true

echo "==> ad-hoc 签名（必须在 strip 之后）"
codesign --force --deep -s - "$BUNDLE" >/dev/null 2>&1 || true
codesign --verify --deep --strict "$BUNDLE" && echo "签名校验通过"

echo "==> 体积"
du -sh "$BUNDLE"
echo "完成：$(pwd)/$BUNDLE"
