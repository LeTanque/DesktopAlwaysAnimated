# Desktop Always Animated

`DesktopAlwaysAnimated` is a small native macOS menu-bar app that continuously loops an installed Apple Aerial video in a desktop-level window. It does not modify `WallpaperAgent`, System Settings, or the selected macOS wallpaper.

## Requirements

- macOS with Xcode Command Line Tools or Xcode
- At least one downloaded Apple Aerial video

## Build and run

```sh
./build.sh
open build/NativeAerialLooper.app
```

The app chooses the most recently downloaded `.mov` from macOS's Aerial cache. To select a specific file instead, launch the executable directly:

```sh
build/NativeAerialLooper.app/Contents/MacOS/NativeAerialLooper --video "/path/to/aerial.mov"
```

Use the app's menu-bar icon to pause/resume playback or quit. Quitting removes its desktop-level video windows immediately.

## Experimental Space Profiles

Choose **Assign Video to This Desktop** from the menu bar while on any macOS Desktop. The assignment is remembered and applied when you switch Spaces. The feature uses an undocumented macOS WindowServer identifier, so it may need adjustment after future macOS updates.

## Notes

Apple’s native Aerial wallpaper system pauses desktop video after the lock/unlock transition. This project is an independent AVFoundation player that produces continuous playback while leaving Apple’s wallpaper service alone.
