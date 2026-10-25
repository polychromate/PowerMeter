#!/bin/bash
# PowerMeter 构建脚本：用系统自带 swiftc 编译，产出可直接双击运行的 .app
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PowerMeter"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)

echo "==> PowerMeter $VERSION"
echo "==> 清理旧构建"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 生成图标"
if [ ! -f Resources/AppIcon.icns ]; then
  swiftc -O Resources/make_icon.swift -o build_make_icon >/dev/null
  ./build_make_icon Resources >/dev/null
  rm -rf Resources/AppIcon.iconset
  mkdir -p Resources/AppIcon.iconset
  for s in 16 32 64 128 256 512; do
    sips -z $s $s Resources/icon_1024.png --out "Resources/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Resources/icon_1024.png --out "Resources/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
  rm -f build_make_icon
fi

echo "==> 编译 Swift 源码"
swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework CoreBluetooth \
  -framework IOBluetooth \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

echo "==> 组装 App Bundle"
cp Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 签名"
# 优先用本地自签证书「PowerMeter Dev」：TCC 授权（输入监控等）绑定固定签名身份，
# 重新编译后无需重新授权；证书不存在时退回 ad-hoc 签名（每次编译后需重新授权）
if security find-identity -v -p codesigning 2>/dev/null | grep -q "PowerMeter Dev"; then
  codesign --force --deep --sign "PowerMeter Dev" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi

echo ""
echo "构建完成：$APP"
echo "运行：open \"$APP\""
