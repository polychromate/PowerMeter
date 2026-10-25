#!/bin/bash
# 打包一个可归档的版本：app 压缩包 + 源码压缩包，放到 releases/ 下
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
mkdir -p releases

./build.sh

rm -f "releases/PowerMeter-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "build/PowerMeter.app" "releases/PowerMeter-$VERSION.zip"

if git rev-parse --git-dir >/dev/null 2>&1; then
  git archive --format=zip --prefix="PowerMeter-$VERSION/" \
    -o "releases/PowerMeter-$VERSION-source.zip" HEAD
  echo "源码包：releases/PowerMeter-$VERSION-source.zip（来自 git HEAD）"
else
  echo "（未初始化 git，跳过源码包）"
fi

echo ""
echo "版本 $VERSION 打包完成："
ls -lh releases | sed '1d'
