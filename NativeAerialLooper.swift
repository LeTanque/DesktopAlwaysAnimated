import AppKit
import AVFoundation
import AVKit
import CoreGraphics

// Undocumented WindowServer calls. They are resolved by macOS today but may
// disappear in a future release, hence the app's experimental Space Profiles UI.
typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ connection: CGSConnectionID) -> UInt64

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
            object: nil,
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

    func setVideo(_ videoURL: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: videoURL))
        if !isPaused { player.play() }
    }

    deinit {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let toolbarIconChoices: [(title: String, symbol: String)] = [
        ("Wallpaper", "rectangle.3.group.fill"),
        ("Photo", "photo"),
        ("Mountains", "mountain.2"),
        ("Play", "play.rectangle.fill"),
        ("Film", "film"),
        ("Video", "video"),
        ("TV", "tv"),
        ("Sparkles", "sparkles"),
        ("Sun", "sun.max.fill"),
        ("Moon", "moon.stars.fill"),
        ("Cloud", "cloud.sun.fill"),
        ("Globe", "globe.americas.fill"),
        ("Leaf", "leaf.fill"),
        ("Waves", "water.waves"),
        ("Desktop", "desktopcomputer")
    ]

    private var controllers: [AerialWindowController] = []
    private var statusItem: NSStatusItem!
    private var playbackMenuItem: NSMenuItem!
    private var toolbarIconMenu: NSMenu!
    private var videos: [URL] = []
    private var profiles: [String: String] = UserDefaults.standard.dictionary(forKey: "spaceProfiles") as? [String: String] ?? [:]
    private lazy var aerialNames = loadAerialNames()

    func applicationDidFinishLaunching(_ notification: Notification) {
        videos = availableVideos()
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        applyProfileForActiveSpace()
    }

    private func installMenu(videoURL: URL) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        applyToolbarIcon()
        statusItem.button?.toolTip = "Native Aerial Looper"
        let menu = NSMenu()
        menu.addItem(withTitle: "Native Aerial Looper", action: nil, keyEquivalent: "")
        let source = menu.addItem(withTitle: displayName(for: videoURL), action: nil, keyEquivalent: "")
        source.isEnabled = false
        menu.addItem(.separator())
        playbackMenuItem = menu.addItem(withTitle: "Pause", action: #selector(togglePlayback), keyEquivalent: "p")
        playbackMenuItem.target = self
        installToolbarIconMenu(in: menu)
        let assignMenu = NSMenu()
        for video in videos {
            let item = assignMenu.addItem(withTitle: displayName(for: video), action: #selector(assignVideo), keyEquivalent: "")
            item.target = self
            item.representedObject = video.path
        }
        let assign = menu.addItem(withTitle: "Assign Video to This Desktop", action: nil, keyEquivalent: "")
        assign.submenu = assignMenu
        let clear = menu.addItem(withTitle: "Clear This Desktop Assignment", action: #selector(clearAssignment), keyEquivalent: "")
        clear.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
    }

    private func installToolbarIconMenu(in menu: NSMenu) {
        toolbarIconMenu = NSMenu()
        let selectedSymbol = UserDefaults.standard.string(forKey: "toolbarIconSymbol") ?? "rectangle.3.group.fill"
        for choice in Self.toolbarIconChoices {
            guard let image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: choice.title) else { continue }
            image.isTemplate = true
            let item = toolbarIconMenu.addItem(withTitle: choice.title, action: #selector(selectToolbarIcon), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.symbol
            item.image = image
            item.state = choice.symbol == selectedSymbol ? .on : .off
        }
        let toolbarIcons = menu.addItem(withTitle: "Toolbar Icons", action: nil, keyEquivalent: "")
        toolbarIcons.submenu = toolbarIconMenu
    }

    private func applyToolbarIcon() {
        let symbol = UserDefaults.standard.string(forKey: "toolbarIconSymbol") ?? "rectangle.3.group.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Aerial Looper")
            ?? NSImage(systemSymbolName: "play.rectangle.fill", accessibilityDescription: "Aerial Looper")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    @objc private func togglePlayback() {
        controllers.forEach { $0.togglePlayback() }
        playbackMenuItem.title = controllers.first?.isPaused == true ? "Resume" : "Pause"
    }

    @objc private func selectToolbarIcon(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        UserDefaults.standard.set(symbol, forKey: "toolbarIconSymbol")
        applyToolbarIcon()
        toolbarIconMenu.items.forEach { item in
            item.state = (item.representedObject as? String) == symbol ? .on : .off
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func assignVideo(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        profiles[activeSpaceKey()] = path
        UserDefaults.standard.set(profiles, forKey: "spaceProfiles")
        applyProfileForActiveSpace()
    }

    @objc private func clearAssignment() {
        profiles.removeValue(forKey: activeSpaceKey())
        UserDefaults.standard.set(profiles, forKey: "spaceProfiles")
    }

    @objc private func spaceDidChange() { applyProfileForActiveSpace() }

    private func activeSpaceKey() -> String { String(CGSGetActiveSpace(CGSMainConnectionID())) }

    private func applyProfileForActiveSpace() {
        guard let path = profiles[activeSpaceKey()], FileManager.default.isReadableFile(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        controllers.forEach { $0.setVideo(url) }
    }

    private func resolveVideoURL() -> URL? {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--video"), args.indices.contains(index + 1) {
            return URL(fileURLWithPath: args[index + 1])
        }
        // macOS stores downloaded Aerials under the user's wallpaper cache.
        // The logical URL in com.apple.wallpaper can refer to an asset that isn't
        // directly present in /System/Library, so choose the most recently
        // downloaded local Aerial when no explicit --video path was supplied.
        return availableVideos().first
    }

    private func availableVideos() -> [URL] {
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
    }

    private func displayName(for video: URL) -> String {
        let identifier = video.deletingPathExtension().lastPathComponent.uppercased()
        return aerialNames[identifier] ?? video.deletingPathExtension().lastPathComponent
    }

    private func loadAerialNames() -> [String: String] {
        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json")
        guard
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let assets = manifest["assets"] as? [[String: Any]]
        else { return [:] }

        return assets.reduce(into: [:]) { names, asset in
            guard
                let identifier = asset["id"] as? String,
                let name = asset["accessibilityLabel"] as? String,
                !name.isEmpty
            else { return }
            names[identifier.uppercased()] = name
        }
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
