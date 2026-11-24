#!/bin/zsh
set -e

DIR="${0:A:h}"
APP="$DIR/dist/FileSeeker.app"
BIN="$APP/Contents/MacOS/FileSeeker"

echo "==> 编译 main.swift"
mkdir -p "$APP/Contents/MacOS"
swiftc -O "$DIR/main.swift" -o "$BIN"

echo "==> 写入 Info.plist"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

echo "==> ad-hoc 签名"
codesign -f -s - "$APP"
codesign -v "$APP" && echo "签名验证通过"

echo "==> 完成: $APP"
echo "    拖入 /Applications 后即可使用"
