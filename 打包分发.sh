#!/bin/bash
# 构建并打出可以直接发给同事的压缩包：dist/轻压-v<版本>.zip
# 用法：./打包分发.sh [版本号，默认读 Info.plist]
set -euo pipefail
cd "$(dirname "$0")"

VER="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
NAME="轻压"

./build.sh

STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE" dist
cp -R "build/$NAME.app" "$STAGE/"
cp "① 先看这里.txt" "$STAGE/"

OUT="dist/$NAME-v$VER.zip"
rm -f "$OUT"
# 用 ditto 打包：能完整保留 .app 的签名和权限。
ditto -c -k --norsrc --noextattr --keepParent "$STAGE" "$OUT"
rm -rf "$(dirname "$STAGE")"

echo
echo "分发包：${PWD}/${OUT}（$(du -h "$OUT" | cut -f1)）"
