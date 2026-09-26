#!/bin/bash
# 构建「轻压」.app —— 只需要 Xcode Command Line Tools
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/轻压.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

# 尽量做通用二进制；机器上缺哪个架构就自动跳过
ARCHS=("arm64" "x86_64")
DEPLOY="13.0"
BRIDGE="Sources/Bridge/libarchive.h"

echo "==> 清理"
rm -rf "$APP" "$BUILD"/QingYa-* "$BUILD"/*.log
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 生成图标"
mkdir -p "$BUILD/icontool"
xcrun swiftc -O -sdk "$SDK" -target "$(uname -m)-apple-macos$DEPLOY" \
    -o "$BUILD/icontool/makeicon" Tools/main.swift
"$BUILD/icontool/makeicon" "$APP/Contents/Resources/AppIcon.icns" "$BUILD/icon.png" >/dev/null

echo "==> 编译"
SOURCES=(Sources/Engine/*.swift Sources/App/*.swift)
SLICES=()
for arch in "${ARCHS[@]}"; do
    out="$BUILD/QingYa-$arch"
    if xcrun swiftc -O -swift-version 5 \
        -sdk "$SDK" -target "$arch-apple-macos$DEPLOY" \
        -import-objc-header "$BRIDGE" -larchive \
        -framework AppKit -framework SwiftUI -framework Security \
        -o "$out" "${SOURCES[@]}" 2>"$BUILD/$arch.log"; then
        SLICES+=("$out")
        echo "    $arch ✓"
    else
        echo "    $arch 跳过（见 $BUILD/$arch.log）"
    fi
done

if [ ${#SLICES[@]} -eq 0 ]; then
    echo "编译失败，日志："
    cat "$BUILD"/*.log
    exit 1
fi

if [ ${#SLICES[@]} -gt 1 ]; then
    lipo -create -output "$APP/Contents/MacOS/QingYa" "${SLICES[@]}"
else
    cp "${SLICES[0]}" "$APP/Contents/MacOS/QingYa"
fi
chmod +x "$APP/Contents/MacOS/QingYa"

echo "==> 打包"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名（ad-hoc）"
codesign --force --deep --sign - --options runtime "$APP" 2>/dev/null \
    || codesign --force --deep --sign - "$APP"
xattr -cr "$APP" || true

echo
echo "完成：$APP"
echo "可直接双击运行，或拖进「应用程序」文件夹。"
