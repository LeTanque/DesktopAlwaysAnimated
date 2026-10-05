#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
app_dir="$project_dir/build/NativeAerialLooper.app"
cache_root="${TMPDIR%/}/desktop-always-animated-swift-cache"
icon_source="$project_dir/assets/NativeAerialLooperIcon.icns"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$cache_root"
cp "$icon_source" "$app_dir/Contents/Resources/NativeAerialLooperIcon.icns"

default_wallpapers_src="$project_dir/samples"
default_wallpapers_dst="$app_dir/Contents/Resources/DefaultWallpapers"
if [[ -d "$default_wallpapers_src" ]]; then
  mkdir -p "$default_wallpapers_dst"
  for video in "$default_wallpapers_src"/*.(mov|mp4|m4v)(N); do
    cp "$video" "$default_wallpapers_dst/"
  done
  if [[ -f "$default_wallpapers_src/wallpaper-names.json" ]]; then
    cp "$default_wallpapers_src/wallpaper-names.json" "$default_wallpapers_dst/"
  fi
fi

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
