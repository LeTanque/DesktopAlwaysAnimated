import AppKit
import AVFoundation
import AVKit
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

// Undocumented WindowServer calls. They are resolved by macOS today but may
// disappear in a future release, hence the app's experimental Space Profiles UI.
typealias CGSConnectionID = UInt32
@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSGetActiveSpace") private func CGSGetActiveSpace(_ connection: CGSConnectionID) -> UInt64
@_silgen_name("CGSCopyManagedDisplaySpaces") private func CGSCopyManagedDisplaySpaces(_ connection: CGSConnectionID) -> CFArray?

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
        ) { [weak self] notification in
            guard let self, !self.isPaused,
                  let item = notification.object as? AVPlayerItem,
                  item === self.player.currentItem else { return }
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

    func close() {
        player.pause()
        window.orderOut(nil)
    }

    deinit {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let supportedVideoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    private static let preferredVideoExtensionOrder = ["mp4", "mov", "m4v"]

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
    private var sourceMenuItem: NSMenuItem!
    private var defaultVideoURL: URL?
    private var currentVideoURL: URL?
    private var videoLoadTask: Task<Void, Never>?
    private var openPanel: NSOpenPanel?
    private var pickerPanel: VideoPickerPanel?
    private let pickerModel = PickerModel()
    private var videos: [URL] = []
    private var profiles: [String: String] = UserDefaults.standard.dictionary(forKey: "spaceProfiles") as? [String: String] ?? [:]
    private lazy var aerialNames = loadAerialNames()
    private lazy var bundledWallpaperNames = loadBundledWallpaperNames()

    func applicationDidFinishLaunching(_ notification: Notification) {
        videos = availableVideos()
        defaultVideoURL = resolveVideoURL()
        installMenu()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceDidChange), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        applyProfileForActiveSpace()
    }

    private func installMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        applyToolbarIcon()
        statusItem.button?.toolTip = "Native Aerial Looper"
        let menu = NSMenu()
        menu.addItem(withTitle: "Native Aerial Looper", action: nil, keyEquivalent: "")
        sourceMenuItem = menu.addItem(withTitle: "No background selected", action: nil, keyEquivalent: "")
        sourceMenuItem.isEnabled = false
        menu.addItem(.separator())
        let configuration = menu.addItem(withTitle: "Configuration…", action: #selector(showConfiguration), keyEquivalent: "o")
        configuration.target = self
        let restart = menu.addItem(withTitle: "Restart Video Wallpaper", action: #selector(restartVideoWallpaper), keyEquivalent: "r")
        restart.target = self
        playbackMenuItem = menu.addItem(withTitle: "Pause", action: #selector(togglePlayback), keyEquivalent: "p")
        playbackMenuItem.target = self
        playbackMenuItem.isEnabled = false
        menu.autoenablesItems = false
        installToolbarIconMenu(in: menu)
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

    @objc private func restartVideoWallpaper() {
        videoLoadTask?.cancel()
        controllers.forEach { $0.close() }
        controllers.removeAll()
        currentVideoURL = nil
        applyProfileForActiveSpace()
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

    @objc private func showConfiguration() {
        pickerPanel?.dismiss()
        refreshPickerModel()
        let view = VideoPickerView(
            model: pickerModel,
            onPick: { [weak self] url in self?.showAssignMenu(for: url) },
            onBrowse: { [weak self] in self?.browseForVideo() },
            onDone: { [weak self] in self?.pickerPanel?.dismiss() }
        )
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = PickerChrome.initialSize(in: visible)
        let panel = VideoPickerPanel(rootView: view, size: size)
        panel.onDismiss = { [weak self, weak panel] in
            if self?.pickerPanel === panel { self?.pickerPanel = nil }
        }
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
        pickerPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: Assignment model
    //
    // `defaultVideoURL` is the All Desktops video and `profiles` holds per-Desktop videos. A Desktop's own
    // video always wins; All Desktops fills the rest; with neither, the app shows nothing and macOS's own
    // wallpaper is visible.

    private func resolvedPath(_ url: URL) -> String { url.resolvingSymlinksInPath().path }

    /// Live Space IDs (all kinds) and the Mission Control number of each regular Desktop.
    private func spaceLayout() -> (ids: Set<String>, numbers: [String: Int]) {
        var ids = Set<String>()
        var numbers: [String: Int] = [:]
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        for display in displays {
            var number = 0
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = (space["ManagedSpaceID"] as? NSNumber)?.stringValue else { continue }
                ids.insert(id)
                if (space["type"] as? NSNumber)?.intValue == 0 {
                    number += 1
                    numbers[id] = number
                }
            }
        }
        return (ids, numbers)
    }

    /// Per-Desktop assignments that point at Desktops that still exist.
    private func liveProfileCount() -> Int {
        let ids = spaceLayout().ids
        return ids.isEmpty ? profiles.count : profiles.keys.filter { ids.contains($0) }.count
    }

    private func refreshPickerModel() {
        videos = availableVideos()
        let layout = spaceLayout()
        var byVideo: [String: [Int]] = [:]
        for (space, path) in profiles {
            guard let number = layout.numbers[space] else { continue }
            byVideo[resolvedPath(URL(fileURLWithPath: path)), default: []].append(number)
        }
        pickerModel.sections = pickerSections()
        pickerModel.allPath = defaultVideoURL.map(resolvedPath)
        pickerModel.desktopNumbers = byVideo.mapValues { $0.sorted() }
        pickerModel.activeDesktop = layout.numbers[activeSpaceKey()]
    }

    private func pickerSections() -> [PickerSection] {
        let aerialDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
            .standardizedFileURL
        let bundled = videos.filter { isBundledVideo($0) }
        let aerials = videos.filter { !isBundledVideo($0) && $0.deletingLastPathComponent().standardizedFileURL == aerialDirectory }
        let mine = videos.filter { !isBundledVideo($0) && $0.deletingLastPathComponent().standardizedFileURL != aerialDirectory }
        // A chosen file is stored as a link; skip links that point at a video already listed above.
        var seen = Set<String>()
        func items(_ list: [URL]) -> [PickerItem] {
            list.compactMap { video in
                guard seen.insert(video.resolvingSymlinksInPath().path).inserted else { return nil }
                return PickerItem(url: video, title: displayName(for: video))
            }
        }
        let sections = [
            PickerSection(name: "DEFAULT WALLPAPERS", items: items(bundled)),
            PickerSection(name: "APPLE AERIALS", items: items(aerials)),
            PickerSection(name: "YOUR VIDEOS", items: items(mine))
        ]
        return sections.filter { !$0.items.isEmpty }
    }

    /// Small menu shown when a tile is clicked. Choosing an entry never closes the picker.
    private func showAssignMenu(for url: URL) {
        let path = resolvedPath(url)
        let thisDesktop = profiles[activeSpaceKey()].map { resolvedPath(URL(fileURLWithPath: $0)) } == path
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all = menu.addItem(withTitle: "All Desktops", action: #selector(toggleAllDesktopsItem(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = url
        all.state = pickerModel.allPath == path ? .on : .off
        let this = menu.addItem(withTitle: "This Desktop", action: #selector(toggleThisDesktopItem(_:)), keyEquivalent: "")
        this.target = self
        this.representedObject = url
        this.state = thisDesktop ? .on : .off
        if let event = NSApp.currentEvent, let view = pickerPanel?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func toggleAllDesktopsItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        toggleAllDesktops(url)
    }

    @objc private func toggleThisDesktopItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        toggleThisDesktop(url)
    }

    private func toggleAllDesktops(_ url: URL) {
        if let current = defaultVideoURL, resolvedPath(current) == resolvedPath(url) {
            // Unchecking All Desktops: Desktops without their own video go back to the macOS wallpaper.
            defaultVideoURL = nil
            UserDefaults.standard.removeObject(forKey: "selectedVideoPath")
            applyProfileForActiveSpace()
            refreshPickerModel()
            return
        }
        let overrideEverything = liveProfileCount() > 0 && confirmOverrideAll(for: url)
        loadVideo(url) { [weak self] in
            guard let self, let managedURL = self.managedLink(for: url) else { return }
            self.defaultVideoURL = managedURL
            UserDefaults.standard.set(managedURL.path, forKey: "selectedVideoPath")
            if overrideEverything {
                self.profiles.removeAll()
                UserDefaults.standard.set(self.profiles, forKey: "spaceProfiles")
            }
            self.applyProfileForActiveSpace()
            self.refreshPickerModel()
        }
    }

    private func toggleThisDesktop(_ url: URL) {
        let key = activeSpaceKey()
        if let assigned = profiles[key], resolvedPath(URL(fileURLWithPath: assigned)) == resolvedPath(url) {
            profiles.removeValue(forKey: key)
            UserDefaults.standard.set(profiles, forKey: "spaceProfiles")
            applyProfileForActiveSpace()
            refreshPickerModel()
            return
        }
        loadVideo(url) { [weak self] in
            guard let self, let managedURL = self.managedLink(for: url) else { return }
            self.profiles[key] = managedURL.path
            UserDefaults.standard.set(self.profiles, forKey: "spaceProfiles")
            self.applyProfileForActiveSpace()
            self.refreshPickerModel()
        }
    }

    private func managedLink(for url: URL) -> URL? {
        guard let managedURL = try? linkVideo(url) else {
            showError("Native Aerial Looper could not create a managed link for “\(url.lastPathComponent)”.\n\nCheck that the file is still available and that the app can write to its Application Support folder.")
            return nil
        }
        return managedURL
    }

    private func confirmOverrideAll(for url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Override all backgrounds?"
        alert.informativeText = "Some Desktops already have their own video.\n\nYes removes those so “\(displayName(for: url))” plays on every Desktop. No keeps them and plays it only on Desktops without their own."
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// BROWSE… adds a file to the picker's Your Videos section; assigning it is a separate click.
    private func browseForVideo() {
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil)
            return
        }
        pickerPanel?.dismiss()
        let panel = NSOpenPanel()
        panel.title = "Add Video"
        panel.message = "Choose a local video that macOS can play, such as MOV, MP4, or M4V."
        panel.prompt = "Add Video"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie]
        // Let AVFoundation decide compatibility, including files with unusual extensions.
        panel.allowsOtherFileTypes = true
        panel.directoryURL = (currentVideoURL ?? defaultVideoURL)?.deletingLastPathComponent()
        openPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard let self else { return }
            self.openPanel = nil
            guard response == .OK, let url = panel.url else {
                self.showConfiguration()
                return
            }
            self.loadVideo(url, onFailure: { [weak self] in self?.showConfiguration() }) { [weak self] in
                guard let self else { return }
                _ = self.managedLink(for: url)
                self.showConfiguration()
            }
        }
    }

    @objc private func clearAssignment() {
        profiles.removeValue(forKey: activeSpaceKey())
        UserDefaults.standard.set(profiles, forKey: "spaceProfiles")
        applyProfileForActiveSpace()
    }

    @objc private func spaceDidChange() {
        applyProfileForActiveSpace()
        if pickerPanel != nil { refreshPickerModel() }
    }

    private func activeSpaceKey() -> String { String(CGSGetActiveSpace(CGSMainConnectionID())) }

    private func applyProfileForActiveSpace() {
        let profileURL = profiles[activeSpaceKey()].map { URL(fileURLWithPath: $0) }
        guard let url = profileURL ?? defaultVideoURL else {
            hideWallpaper()
            return
        }
        loadVideo(url, onFailure: { [weak self] in
            guard let self else { return }
            if profileURL != nil, let fallback = self.defaultVideoURL, fallback != url {
                self.loadVideo(fallback) { self.showVideo(fallback) }
            } else if self.controllers.isEmpty {
                self.showConfiguration()
            }
        }) { [weak self] in self?.showVideo(url) }
    }

    /// No video applies to this Desktop: take our windows away so the macOS wallpaper shows.
    private func hideWallpaper() {
        videoLoadTask?.cancel()
        controllers.forEach { $0.close() }
        controllers.removeAll()
        currentVideoURL = nil
        sourceMenuItem.title = "Showing the macOS wallpaper"
        sourceMenuItem.toolTip = nil
        playbackMenuItem.title = "Pause"
        playbackMenuItem.isEnabled = false
    }

    private func loadVideo(_ url: URL, onFailure: (() -> Void)? = nil, onSuccess: @escaping () -> Void) {
        videoLoadTask?.cancel()
        videoLoadTask = Task { @MainActor [weak self] in
            do {
                let resolvedURL = url.resolvingSymlinksInPath()
                guard FileManager.default.isReadableFile(atPath: resolvedURL.path),
                      (try resolvedURL.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    throw VideoSelectionError.unreadable
                }
                let asset = AVURLAsset(url: url)
                let playable = try await asset.load(.isPlayable)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard playable, !tracks.isEmpty else { throw VideoSelectionError.unsupported }
                guard !Task.isCancelled else { return }
                onSuccess()
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.showError("Cannot use “\(url.lastPathComponent)” as a background.\n\nChoose a readable video with a video track and a codec supported by macOS.\n\n\(error.localizedDescription)")
                if let onFailure {
                    onFailure()
                } else if self.controllers.isEmpty {
                    self.showConfiguration()
                }
            }
        }
    }

    private func showVideo(_ url: URL) {
        if controllers.isEmpty {
            controllers = NSScreen.screens.map {
                let controller = AerialWindowController(screen: $0, videoURL: url)
                controller.show()
                return controller
            }
        } else if currentVideoURL != url {
            controllers.forEach { $0.setVideo(url) }
        }
        currentVideoURL = url
        sourceMenuItem.title = displayName(for: url)
        sourceMenuItem.toolTip = url.path
        playbackMenuItem.isEnabled = true
    }

    private func managedVideoDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Native Aerial Looper/Videos", isDirectory: true)
    }

    private func bundledVideoDirectory() -> URL? {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("DefaultWallpapers", isDirectory: true),
              FileManager.default.fileExists(atPath: directory.path)
        else { return nil }
        return directory
    }

    private func linkVideo(_ url: URL) throws -> URL {
        let directory = managedVideoDirectory()
        let source = url.standardizedFileURL
        let managedPrefix = directory.standardizedFileURL.path + "/"
        if source.path.hasPrefix(managedPrefix) { return source }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseName = url.deletingPathExtension().lastPathComponent
        let extensionName = url.pathExtension
        var suffix = 1
        var candidate: URL
        repeat {
            let name = suffix == 1 ? baseName : "\(baseName) (\(suffix))"
            candidate = directory.appendingPathComponent(name)
            if !extensionName.isEmpty { candidate.appendPathExtension(extensionName) }
            if let existingDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: candidate.path),
               URL(fileURLWithPath: existingDestination).standardizedFileURL == source {
                return candidate
            }
            suffix += 1
        } while FileManager.default.fileExists(atPath: candidate.path)

        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: source)
        return candidate
    }

    private func resolveVideoURL() -> URL? {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--video"), args.indices.contains(index + 1) {
            return URL(fileURLWithPath: args[index + 1])
        }
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: "selectedVideoPath") {
            defaults.set(true, forKey: "didInitialSetup")
            return URL(fileURLWithPath: path)
        }
        // First launch only: play a random bundled wallpaper on All Desktops. After that, no saved
        // video means the user removed it on purpose, so it is not chosen again.
        guard !defaults.bool(forKey: "didInitialSetup") else { return nil }
        defaults.set(true, forKey: "didInitialSetup")
        let all = availableVideos()
        guard let pick = all.filter(isBundledVideo).randomElement() ?? all.first,
              let managedURL = try? linkVideo(pick)
        else { return nil }
        defaults.set(managedURL.path, forKey: "selectedVideoPath")
        return managedURL
    }

    private func availableVideos() -> [URL] {
        let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos")
        let managedDirectory = managedVideoDirectory()
        let bundledDirectory = bundledVideoDirectory()
        var directories = [cacheDirectory, managedDirectory]
        if let bundledDirectory { directories.append(bundledDirectory) }
        let videos = directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        var seen = Set<String>()
        return videos
            .filter { video in
                guard Self.supportedVideoExtensions.contains(video.pathExtension.lowercased()) else { return false }
                let parent = video.deletingLastPathComponent().standardizedFileURL
                if parent == managedDirectory.standardizedFileURL { return true }
                if let bundledDirectory, parent == bundledDirectory.standardizedFileURL { return true }
                return parent == cacheDirectory.standardizedFileURL
            }
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .filter(dedupedBundledVideos)
            .sorted { left, right in
                let leftBundled = isBundledVideo(left)
                let rightBundled = isBundledVideo(right)
                if leftBundled != rightBundled { return leftBundled }
                if leftBundled {
                    return displayName(for: left).localizedCaseInsensitiveCompare(displayName(for: right)) == .orderedAscending
                }
                let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return leftDate > rightDate
            }
    }

    private func isBundledVideo(_ video: URL) -> Bool {
        guard let bundledDirectory = bundledVideoDirectory() else { return false }
        return video.deletingLastPathComponent().standardizedFileURL == bundledDirectory.standardizedFileURL
    }

    private func dedupedBundledVideos(_ video: URL) -> Bool {
        guard isBundledVideo(video), let bundledDirectory = bundledVideoDirectory() else { return true }
        let stem = video.deletingPathExtension().lastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: bundledDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.deletingPathExtension().lastPathComponent == stem
                && Self.supportedVideoExtensions.contains($0.pathExtension.lowercased())
        } ?? [video]
        guard let preferred = siblings.min(by: preferredVideoExtensionRank) else { return true }
        return video.standardizedFileURL == preferred.standardizedFileURL
    }

    private func preferredVideoExtensionRank(_ left: URL, _ right: URL) -> Bool {
        let leftRank = Self.preferredVideoExtensionOrder.firstIndex(of: left.pathExtension.lowercased()) ?? Int.max
        let rightRank = Self.preferredVideoExtensionOrder.firstIndex(of: right.pathExtension.lowercased()) ?? Int.max
        if leftRank != rightRank { return leftRank < rightRank }
        return left.lastPathComponent.localizedCaseInsensitiveCompare(right.lastPathComponent) == .orderedAscending
    }

    private func displayName(for video: URL) -> String {
        // A managed link ("Name (2).mp4") is named after what it points at.
        let stem = video.resolvingSymlinksInPath().deletingPathExtension().lastPathComponent
        if let bundledName = bundledWallpaperNames[stem] { return bundledName }
        let identifier = stem.uppercased()
        return aerialNames[identifier] ?? stem
    }

    private func loadBundledWallpaperNames() -> [String: String] {
        guard let manifestURL = bundledVideoDirectory()?.appendingPathComponent("wallpaper-names.json"),
              let data = try? Data(contentsOf: manifestURL),
              let names = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return names
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
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Custom video picker

enum PickerChrome {
    static let accent = Color(red: 47.0 / 255.0, green: 211.0 / 255.0, blue: 200.0 / 255.0)
    static let highlight = Color(red: 255.0 / 255.0, green: 194.0 / 255.0, blue: 61.0 / 255.0)
    static let label = Color(white: 0.56)
    static let chamfer: CGFloat = 12
    static let windowChamfer: CGFloat = 18
    static let minimumSize = NSSize(width: 600, height: 440)
    private static let sizeKey = "pickerSize"

    /// Last size the user resized to, else a large default scaled to the screen.
    static func initialSize(in visible: NSRect) -> NSSize {
        var size = NSSize(
            width: min(max(visible.width * 0.72, 960), 1280),
            height: min(max(visible.height * 0.78, 680), 880)
        )
        if let saved = UserDefaults.standard.string(forKey: sizeKey) {
            let restored = NSSizeFromString(saved)
            if restored.width > 0, restored.height > 0 { size = restored }
        }
        size.width = min(max(size.width, minimumSize.width), visible.width)
        size.height = min(max(size.height, minimumSize.height), visible.height)
        return size
    }

    static func remember(size: NSSize) {
        UserDefaults.standard.set(NSStringFromSize(size), forKey: sizeKey)
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom("Menlo", size: size).weight(bold ? .bold : .regular)
    }
}

/// "Desktop 2", "Desktop 2 and 4", "Desktop 2, 4, and 5".
func assignmentLabel(forDesktops numbers: [Int]) -> String {
    let list = numbers.map(String.init)
    switch list.count {
    case 0: return ""
    case 1: return "Desktop \(list[0])"
    case 2: return "Desktop \(list[0]) and \(list[1])"
    default: return "Desktop \(list.dropLast().joined(separator: ", ")), and \(list[list.count - 1])"
    }
}

/// Rectangle with the bottom-right corner cut, matching the MetricsWidget tiles.
struct ChamferedShape: Shape {
    var chamfer: CGFloat = PickerChrome.chamfer

    func path(in rect: CGRect) -> Path {
        let cut = min(max(chamfer, 0), min(rect.width, rect.height))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - cut))
        path.addLine(to: CGPoint(x: rect.maxX - cut, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct PickerItem: Identifiable {
    let url: URL
    let title: String
    let resolvedPath: String
    var id: String { url.path }

    init(url: URL, title: String) {
        self.url = url
        self.title = title
        self.resolvedPath = url.resolvingSymlinksInPath().path
    }
}

struct PickerSection: Identifiable {
    let name: String
    let items: [PickerItem]
    var id: String { name }
}

/// What the picker shows: videos plus where each one is assigned. Updated live by the app.
final class PickerModel: ObservableObject {
    @Published var sections: [PickerSection] = []
    @Published var allPath: String?
    @Published var desktopNumbers: [String: [Int]] = [:]
    @Published var activeDesktop: Int?
}

struct AssignmentBadge: Identifiable {
    let text: String
    let isAll: Bool
    var id: String { text }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL) async -> NSImage? {
        let key = url.resolvingSymlinksInPath().path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 520, height: 292)
        do {
            let duration = try await asset.load(.duration).seconds
            let seconds = duration.isFinite && duration > 1 ? duration * 0.3 : 0
            let (cgImage, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            cache.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
}

/// Muted, looping preview that plays while the pointer rests on a tile.
final class PreviewPlayerView: NSView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    init(url: URL) {
        super.init(frame: .zero)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        layer = playerLayer
        wantsLayer = true
        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.play()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func stop() {
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
    }
}

struct LoopingPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PreviewPlayerView { PreviewPlayerView(url: url) }
    func updateNSView(_ view: PreviewPlayerView, context: Context) {}
    static func dismantleNSView(_ view: PreviewPlayerView, coordinator: ()) { view.stop() }
}

struct PickerTile: View {
    let item: PickerItem
    let badges: [AssignmentBadge]
    let onPick: (URL) -> Void
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var previewing = false

    var body: some View {
        Button(action: { onPick(item.url) }) {
            VStack(alignment: .leading, spacing: 7) {
                Color.black.opacity(0.4)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .overlay {
                        if let image {
                            Image(nsImage: image).resizable().scaledToFill()
                        }
                    }
                    .overlay {
                        if previewing {
                            LoopingPreview(url: item.url).allowsHitTesting(false)
                        }
                    }
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(badges) { badge in
                                Text(badge.text)
                                    .font(PickerChrome.font(9, bold: true))
                                    .foregroundStyle(Color.black)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(badge.isAll ? PickerChrome.accent : PickerChrome.highlight)
                            }
                        }
                        .padding(6)
                    }
                Text(item.title)
                    .font(PickerChrome.font(11, bold: true))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(8)
            .background(ChamferedShape().fill(Color.black.opacity(hovering ? 0.34 : 0.22)))
            .overlay {
                ChamferedShape()
                    .stroke(PickerChrome.accent.opacity(hovering ? 1 : (badges.isEmpty ? 0 : 0.45)), lineWidth: 1.5)
            }
            .clipShape(ChamferedShape())
            .contentShape(ChamferedShape())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task(id: hovering) {
            if hovering {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { previewing = true }
            } else {
                previewing = false
            }
        }
        .task { image = await ThumbnailCache.shared.image(for: item.url) }
    }
}

/// Square-cornered button; only the window and tiles carry the chamfer.
struct PickerButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PickerChrome.font(11, bold: true))
                .foregroundStyle(PickerChrome.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Rectangle().fill(Color.black.opacity(hovering ? 0.5 : 0.35)))
                .overlay(Rectangle().stroke(PickerChrome.accent.opacity(hovering ? 1 : 0.5), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct VideoPickerView: View {
    @ObservedObject var model: PickerModel
    let onPick: (URL) -> Void
    let onBrowse: () -> Void
    let onDone: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12, alignment: .top)]

    private var subtitle: String {
        var text = "CLICK A BACKGROUND TO ASSIGN IT"
        if let desktop = model.activeDesktop { text += "  ·  YOU ARE ON DESKTOP \(desktop)" }
        return text
    }

    private func badges(for item: PickerItem) -> [AssignmentBadge] {
        var result: [AssignmentBadge] = []
        if model.allPath == item.resolvedPath {
            result.append(AssignmentBadge(text: "ALL DESKTOPS", isAll: true))
        }
        if let numbers = model.desktopNumbers[item.resolvedPath], !numbers.isEmpty {
            result.append(AssignmentBadge(text: assignmentLabel(forDesktops: numbers).uppercased(), isAll: false))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONFIGURATION")
                        .font(PickerChrome.font(14, bold: true))
                        .foregroundStyle(Color.white)
                    Text(subtitle)
                        .font(PickerChrome.font(10, bold: true))
                        .foregroundStyle(PickerChrome.label)
                }
                Spacer()
                PickerButton(title: "BROWSE…", action: onBrowse)
            }
            .padding(14)
            .background(Color.black.opacity(0.35))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(model.sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.name)
                                .font(PickerChrome.font(10, bold: true))
                                .tracking(1.5)
                                .foregroundStyle(PickerChrome.label)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(section.items) { item in
                                    PickerTile(item: item, badges: badges(for: item), onPick: onPick)
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }

            HStack {
                Text("ESC OR CLICK OUTSIDE TO CLOSE  ·  BROWSE… ADDS ANY OTHER FILE")
                    .font(PickerChrome.font(9))
                    .foregroundStyle(PickerChrome.label)
                Spacer()
                PickerButton(title: "DONE", action: onDone)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.35))
        }
    }
}

/// Blurred backdrop whose bottom-right corner is cut; the cut is rebuilt whenever the window resizes.
final class ChamferedEffectView: NSVisualEffectView {
    override func layout() {
        super.layout()
        let cut = PickerChrome.windowChamfer
        let width = bounds.width
        let height = bounds.height
        // AppKit origin is bottom-left.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: width - cut, y: 0))
        path.addLine(to: CGPoint(x: width, y: cut))
        path.addLine(to: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.path = path
        layer?.mask = mask
    }
}

final class VideoPickerPanel: NSPanel, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    private var dismissed = false
    private var deactivationObserver: NSObjectProtocol?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(rootView: VideoPickerView, size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace]
        minSize = PickerChrome.minimumSize
        delegate = self

        let effect = ChamferedEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true

        let tint = NSView(frame: effect.bounds)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        effect.addSubview(tint)

        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = effect.bounds
        hosting.autoresizingMask = [.width, .height]
        effect.addSubview(hosting)

        contentView = effect

        // Clicking anywhere outside the app closes the picker. Menus, the override prompt, and the
        // file chooser keep the app active, so they leave it open.
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.dismiss() }
    }

    func windowDidResize(_ notification: Notification) { PickerChrome.remember(size: frame.size) }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
        deactivationObserver = nil
        close()
        onDismiss?()
    }
}

private enum VideoSelectionError: LocalizedError {
    case unreadable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The file is missing, inaccessible, or is not a regular file."
        case .unsupported: return "This file does not contain video that macOS can play."
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
