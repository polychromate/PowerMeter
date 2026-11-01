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
  -framework JavaScriptCore \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

echo "==> 编译桌面小组件"
APPEX="$APP/Contents/PlugIns/PowerMeterWidget.appex"
rm -rf "$APPEX"
mkdir -p "$APPEX/Contents/MacOS"
# -Xlinker -e -Xlinker _NSExtensionMain 是这条链路的关键：
# 手工 swiftc 编出来的二进制入口是 Swift 的 main，WidgetKit 的 @main 会掉进 ExtensionFoundation，
# 认不出这是个 widget 扩展，进程在回答 getAllDescriptors 之前就退出——表现为「扩展注册成功、
# 但小组件面板永远是空的」。Xcode 产出的 widget 二进制入口都是 _NSExtensionMain。
swiftc -O -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -framework WidgetKit \
  -framework SwiftUI \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$APPEX/Contents/MacOS/PowerMeterWidget" \
  Widget/*.swift
cp Widget/Info.plist "$APPEX/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APPEX/Contents/Info.plist" >/dev/null
# 系统按 appex 的 CFBundleVersion 缓存小组件描述符；版本不变就一直用旧的，
# 改了代码也看不见效果。每次构建用时间戳递增。
APPEX_BUILD=$(date +%Y%m%d%H%M)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APPEX_BUILD" "$APPEX/Contents/Info.plist" >/dev/null

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
  SIGN_ID="PowerMeter Dev"
else
  SIGN_ID="-"
fi

# 先签内层扩展（要带沙盒 entitlement），再签主体。
# 这里刻意不用 --deep：它会把同一套参数套到嵌套代码上，把扩展的 entitlement 抹掉，
# 结果就是小组件能注册但加载失败。
codesign --force --sign "$SIGN_ID" --entitlements Widget/PowerMeterWidget.entitlements "$APPEX"
codesign --force --sign "$SIGN_ID" "$APP"

echo ""
echo "构建完成：$APP"
echo "运行：open \"$APP\""
