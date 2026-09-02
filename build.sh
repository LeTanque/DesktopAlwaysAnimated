#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/build/NativeAerialLooper.app"
cache_root="${TMPDIR%/}/desktop-always-animated-swift-cache"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$cache_root"

CLANG_MODULE_CACHE_PATH="$cache_root" \
SWIFT_MODULECACHE_PATH="$cache_root" \
swiftc "$project_dir/NativeAerialLooper.swift" \
  -framework AppKit \
  -framework AVFoundation \
  -framework AVKit \
  -framework CoreGraphics \
  -o "$app_dir/Contents/MacOS/NativeAerialLooper"

cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"
xattr -cr "$app_dir"
codesign --force --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

echo "Built $app_dir"
