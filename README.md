# Desktop Always Animated

`DesktopAlwaysAnimated` is a small native macOS menu-bar app that continuously loops an installed Apple Aerial video, or another compatible `.mov` or `.mp4` video, in a desktop-level window. It does not modify `WallpaperAgent`, System Settings, or the selected macOS wallpaper.

The app uses its original vector icon from [`assets/NativeAerialLooperIcon.svg`](assets/NativeAerialLooperIcon.svg). The checked-in PNG and native ICNS renders are copied into the app bundle by `build.sh`.

<img width="630" height="469" alt="Screenshot 2026-09-02 at 1 48 52 AM" src="https://github.com/user-attachments/assets/088d38a5-4ab4-4c7c-82c4-a12b1ec152a7" />
<img width="437" height="532" alt="Screenshot 2026-09-02 at 1 48 48 AM" src="https://github.com/user-attachments/assets/85830501-a24d-43a0-b568-0227b07f38a4" />



## Requirements

- macOS with Xcode Command Line Tools or Xcode
- A local video that macOS can play, or a downloaded Apple Aerial video

## Build and run

```sh
./build.sh
open build/NativeAerialLooper.app
```

## Included sample backgrounds

The [`samples`](samples) folder contains two original ten-second motion loops that are ready to use:

- [`sample-motion.mp4`](samples/sample-motion.mp4) — H.264 in an MP4 container
- [`sample-motion.mov`](samples/sample-motion.mov) — H.264 in a MOV container

Choose either file from **Choose Background Video…**, or launch one directly:

```sh
build/NativeAerialLooper.app/Contents/MacOS/NativeAerialLooper --video "$(pwd)/samples/sample-motion.mp4"
```

Open the menu-bar icon and choose **Choose Background Video…** to browse anywhere on your Mac, including external drives. Select a compatible video and click **Use Video**. The app checks that it contains playable video before switching, and remembers your selection across launches. Cancelling or selecting an invalid file leaves the current background unchanged.

MOV, MP4, and M4V are common choices; actual compatibility depends on the video's codec and macOS. Animated GIFs, web pages, and animation project files must be exported to a compatible video first. Files play from their original location, so keep the selected file available.

On first launch, the app uses the newest cached Aerial if available, otherwise it opens the file picker. If a saved file becomes unavailable, the app lets you choose a replacement. To override the saved default for one launch, use:

```sh
build/NativeAerialLooper.app/Contents/MacOS/NativeAerialLooper --video "/path/to/aerial.mov"
```

MP4 files using codecs supported by macOS, such as H.264 or HEVC, play directly and do not need conversion:

```sh
build/NativeAerialLooper.app/Contents/MacOS/NativeAerialLooper --video "/path/to/background.mp4"
```

If a workflow specifically requires a `.mov` container, an MP4 can usually be remuxed without re-encoding or quality loss:

```sh
ffmpeg -i input.mp4 -map 0 -c copy output.mov
```

To start it automatically after login, build first, then run:

```sh
./install-login-item.sh
```

This installs a user-level launch agent with no restart loop. It launches independently after login, so a missing app or crash cannot block macOS sign-in. Remove it with `./uninstall-login-item.sh`.

Use the app's menu-bar icon to pause/resume playback or quit. Quitting removes its desktop-level video windows immediately.

## Experimental Space Profiles

Choose **Assign Video to This Desktop** from the menu bar while on any macOS Desktop. The assignment is remembered and applied when you switch Spaces. The feature uses an undocumented macOS WindowServer identifier, so it may need adjustment after future macOS updates.

Use **Choose Video…** in that submenu to assign a file from anywhere on disk, or select a cached Aerial. **Clear This Desktop Assignment** restores the default background. **Choose Background Video…** sets the default and clears the current Desktop's assignment so the new choice appears immediately; other Desktop assignments remain in place.

## Notes

Apple’s native Aerial wallpaper system pauses desktop video after the lock/unlock transition. This project is an independent AVFoundation player that produces continuous playback while leaving Apple’s wallpaper service alone.
