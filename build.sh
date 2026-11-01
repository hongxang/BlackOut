#!/bin/bash
# BlackOut 一键黑屏 — 构建脚本
set -euo pipefail
cd "$(dirname "$0")"

APP="BlackOut.app"
ICON_SRC="icon-source.png"
ICONSET="BlackOut.iconset"

# 1) 由源图生成 icns（源图存在时）
if [ -f "$ICON_SRC" ]; then
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  sips -z 16 16     "$ICON_SRC" --out "$ICONSET/icon_16x16.png"       >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_16x16@2x.png"    >/dev/null
  sips -z 32 32     "$ICON_SRC" --out "$ICONSET/icon_32x32.png"       >/dev/null
  sips -z 64 64     "$ICON_SRC" --out "$ICONSET/icon_32x32@2x.png"     >/dev/null
  sips -z 128 128   "$ICON_SRC" --out "$ICONSET/icon_128x128.png"     >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_128x128@2x.png"  >/dev/null
  sips -z 256 256   "$ICON_SRC" --out "$ICONSET/icon_256x256.png"     >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_256x256@2x.png"  >/dev/null
  sips -z 512 512   "$ICON_SRC" --out "$ICONSET/icon_512x512.png"     >/dev/null
  sips -z 1024 1024 "$ICON_SRC" --out "$ICONSET/icon_512x512@2x.png"  >/dev/null
  iconutil -c icns "$ICONSET" -o BlackOut.icns
  rm -rf "$ICONSET"
fi

# 2) 组装 bundle
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -o "$APP/Contents/MacOS/BlackOut" main.swift
cp Info.plist "$APP/Contents/"
[ -f BlackOut.icns ] && cp BlackOut.icns "$APP/Contents/Resources/BlackOut.icns"

# 3) ad-hoc 签名（本机构建无隔离标记，可直接运行）
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

echo "✔ 构建完成: $PWD/$APP"
