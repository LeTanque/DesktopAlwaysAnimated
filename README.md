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

## Included default wallpapers

The [`samples`](samples) folder holds the default motion loops shipped inside every build. `build.sh` copies them into the app bundle as `DefaultWallpapers`, so they appear in the video picker on a fresh install without downloading Apple Aerials or picking a file first. Friendly menu titles come from [`samples/wallpaper-names.json`](samples/wallpaper-names.json).

The videos in `samples/` are stored with [Git LFS](https://git-lfs.com). Install it once before cloning or building (`brew install git-lfs && git lfs install`), otherwise the files are tiny pointer text files and will not play.

Add more `.mov`, `.mp4`, or `.m4v` files to `samples/` before building to ship additional defaults. Choose any bundled wallpaper from the video picker, or launch one directly:

```sh
build/NativeAerialLooper.app/Contents/MacOS/NativeAerialLooper --video "$(pwd)/samples/FlyingInSpace.mp4"
```

Open the menu-bar icon and choose **Configuration…** to open the video picker, then click **BROWSE…** to add a video from anywhere on your Mac, including external drives. The app checks that it contains playable video, then lists it under **Your Videos** (click it to assign it). Cancelling or selecting an invalid file changes nothing.

MOV, MP4, and M4V are common choices; actual compatibility depends on the video's codec and macOS. Animated GIFs, web pages, and animation project files must be exported to a compatible video first. A selected file is represented by a symbolic link in `~/Library/Application Support/Native Aerial Looper/Videos`, so it also appears in the picker's **Your Videos** section without duplicating the media. Keep the original file available while using the link.

On first launch, the app plays one of the bundled default wallpapers, chosen at random, on All Desktops; the picker shows it with an **ALL DESKTOPS** label. That happens only once: if you later remove the All Desktops video, the macOS wallpaper shows and the app does not pick another one. If a saved file becomes unavailable, the app tells you and opens the picker. To override the saved default for one launch, use:

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

Open **Configuration…** while on any macOS Desktop, click a video, and choose **This Desktop**. The assignment is remembered and applied when you switch Spaces. Desktop numbers follow Mission Control order (Desktop 1, 2, …). The feature uses undocumented macOS WindowServer calls, so it may need adjustment after future macOS updates.

The picker (**Configuration…**) is the control center for backgrounds. It opens large, can be resized by dragging its edges (the size is remembered), and shows a looping preview when you rest the pointer on a tile. Each video is labeled with where it is used: **ALL DESKTOPS**, and **DESKTOP 2**, **DESKTOP 2 AND 4**, or **DESKTOP 2, 4, AND 5**. Both labels can appear on one video.

Click a video to open a small menu with **All Desktops** and **This Desktop**. A checkmark means that assignment is on; choose the checked entry again to remove it. The picker stays open while you work. Click **DONE**, press Esc, or click outside the window to close it.

A Desktop's own video always plays instead of the All Desktops video. If you set All Desktops while some Desktops have their own video, the app asks **Override all backgrounds?** Yes removes every Desktop's own video; No keeps them, so the new video plays only on Desktops without one. When a Desktop has neither, the app shows nothing and the macOS wallpaper is visible. **Clear This Desktop Assignment** in the menu-bar menu removes the current Desktop's own video.

## Notes

Apple’s native Aerial wallpaper system pauses desktop video after the lock/unlock transition. This project is an independent AVFoundation player that produces continuous playback while leaving Apple’s wallpaper service alone.
