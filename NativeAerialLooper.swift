import AppKit
import AVFoundation
import AVKit
import CoreGraphics

final class AerialWindowController {
    private let screen: NSScreen
    private let player: AVPlayer
    private let window: NSWindow
    private var loopObserver: NSObjectProtocol?
    private(set) var isPaused = false

    init(screen: NSScreen, videoURL: URL) {
        self.screen = screen
        self.player = AVPlayer(url: videoURL)
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        self.window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.level = level
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let playerView = AVPlayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspectFill
        window.contentView = playerView

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.player.seek(to: .zero)
            self.player.play()
        }
    }

    func show() {
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        player.play()
    }

    func togglePlayback() {
        if isPaused { player.play() } else { player.pause() }
        isPaused.toggle()
    }

    deinit {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [AerialWindowController] = []
    private var statusItem: NSStatusItem!
    private var playbackMenuItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let videoURL = resolveVideoURL() else {
            showError("No Aerial video was found. Relaunch with: --video /path/to/file.mov")
            NSApp.terminate(nil)
            return
        }
        guard FileManager.default.isReadableFile(atPath: videoURL.path) else {
            showError("The selected video is not readable:\n\(videoURL.path)")
            NSApp.terminate(nil)
            return
        }
        controllers = NSScreen.screens.map {
            let controller = AerialWindowController(screen: $0, videoURL: videoURL)
            controller.show()
            return controller
        }
        installMenu(videoURL: videoURL)
    }

    private func installMenu(videoURL: URL) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "Aerial Looper")
        statusItem.button?.toolTip = "Native Aerial Looper"
        let menu = NSMenu()
        menu.addItem(withTitle: "Native Aerial Looper", action: nil, keyEquivalent: "")
        let source = menu.addItem(withTitle: videoURL.lastPathComponent, action: nil, keyEquivalent: "")
        source.isEnabled = false
        menu.addItem(.separator())
        playbackMenuItem = menu.addItem(withTitle: "Pause", action: #selector(togglePlayback), keyEquivalent: "p")
        playbackMenuItem.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
    }

    @objc private func togglePlayback() {
        controllers.forEach { $0.togglePlayback() }
        playbackMenuItem.title = controllers.first?.isPaused == true ? "Resume" : "Pause"
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func resolveVideoURL() -> URL? {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--video"), args.indices.contains(index + 1) {
            return URL(fileURLWithPath: args[index + 1])
        }
        // macOS stores downloaded Aerials under the user's wallpaper cache.
        // The logical URL in com.apple.wallpaper can refer to an asset that isn't
        // directly present in /System/Library, so choose the most recently
        // downloaded local Aerial when no explicit --video path was supplied.
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
        let videos = (try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return videos
            .filter { $0.pathExtension.lowercased() == "mov" }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return left > right
            }
            .first
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Native Aerial Looper"
        alert.informativeText = message
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
