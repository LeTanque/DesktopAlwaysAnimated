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
    private var assignMenu: NSMenu!
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
        let choose = menu.addItem(withTitle: "Choose Video for All Desktops…", action: #selector(chooseBackgroundVideo), keyEquivalent: "o")
        choose.target = self
        let chooseDesktop = menu.addItem(withTitle: "Choose Video for This Desktop…", action: #selector(chooseDesktopVideo), keyEquivalent: "")
        chooseDesktop.target = self
        let restart = menu.addItem(withTitle: "Restart Video Wallpaper", action: #selector(restartVideoWallpaper), keyEquivalent: "r")
        restart.target = self
        playbackMenuItem = menu.addItem(withTitle: "Pause", action: #selector(togglePlayback), keyEquivalent: "p")
        playbackMenuItem.target = self
        playbackMenuItem.isEnabled = false
        menu.autoenablesItems = false
        installToolbarIconMenu(in: menu)
        assignMenu = NSMenu()
        refreshAssignMenu()
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

    @objc private func chooseBackgroundVideo() { showPicker(forSpace: nil) }

    @objc private func chooseDesktopVideo() { showPicker(forSpace: activeSpaceKey()) }

    private func showPicker(forSpace space: String?) {
        pickerPanel?.dismiss()
        videos = availableVideos()
        let activeURL = space == nil ? defaultVideoURL : currentVideoURL
        let view = VideoPickerView(
            subtitle: space == nil ? "FOR ALL DESKTOPS" : "FOR THIS DESKTOP",
            sections: pickerSections(),
            activePath: activeURL?.resolvingSymlinksInPath().path,
            onPick: { [weak self] url in
                self?.pickerPanel?.dismiss()
                self?.selectVideo(url, forSpace: space)
            },
            onBrowse: { [weak self] in
                self?.pickerPanel?.dismiss()
                self?.chooseVideo(forSpace: space)
            },
            onClose: { [weak self] in self?.pickerPanel?.dismiss() }
        )
        let panel = VideoPickerPanel(rootView: view)
        panel.onDismiss = { [weak self, weak panel] in
            if self?.pickerPanel === panel { self?.pickerPanel = nil }
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: frame.midX - PickerChrome.windowSize.width / 2,
                y: frame.midY - PickerChrome.windowSize.height / 2
            ))
        }
        pickerPanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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

    private func chooseVideo(forSpace space: String?) {
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.title = space == nil ? "Choose Video for All Desktops" : "Choose Video for This Desktop"
        panel.message = "Choose a local video that macOS can play, such as MOV, MP4, or M4V."
        panel.prompt = "Use Video"
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
            guard response == .OK, let url = panel.url else { return }
            self.selectVideo(url, forSpace: space)
        }
    }

    private func selectVideo(_ url: URL, forSpace space: String?) {
        loadVideo(url) { [weak self] in
            guard let self else { return }
            guard let managedURL = try? self.linkVideo(url) else {
                self.showError("Native Aerial Looper could not create a managed link for “\(url.lastPathComponent)”.\n\nCheck that the file is still available and that the app can write to its Application Support folder.")
                return
            }
            self.videos = self.availableVideos()
            self.refreshAssignMenu()
            if let space {
                self.profiles[space] = managedURL.path
            } else {
                self.defaultVideoURL = managedURL
                UserDefaults.standard.set(managedURL.path, forKey: "selectedVideoPath")
                // "All Desktops" means all of them: drop every per-Desktop assignment so the new
                // default shows everywhere, including Desktops that had their own video.
                self.profiles.removeAll()
            }
            UserDefaults.standard.set(self.profiles, forKey: "spaceProfiles")
            self.applyProfileForActiveSpace()
        }
    }

    @objc private func assignVideo(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        selectVideo(URL(fileURLWithPath: path), forSpace: activeSpaceKey())
    }

    @objc private func clearAssignment() {
        profiles.removeValue(forKey: activeSpaceKey())
        UserDefaults.standard.set(profiles, forKey: "spaceProfiles")
        applyProfileForActiveSpace()
    }

    @objc private func spaceDidChange() { applyProfileForActiveSpace() }

    private func activeSpaceKey() -> String { String(CGSGetActiveSpace(CGSMainConnectionID())) }

    private func applyProfileForActiveSpace() {
        let profileURL = profiles[activeSpaceKey()].map { URL(fileURLWithPath: $0) }
        guard let url = profileURL ?? defaultVideoURL else {
            chooseBackgroundVideo()
            return
        }
        loadVideo(url, onFailure: { [weak self] in
            guard let self else { return }
            if profileURL != nil, let fallback = self.defaultVideoURL, fallback != url {
                self.loadVideo(fallback) { self.showVideo(fallback) }
            } else if self.controllers.isEmpty {
                self.chooseBackgroundVideo()
            }
        }) { [weak self] in self?.showVideo(url) }
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
                    self.chooseBackgroundVideo()
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

    private func refreshAssignMenu() {
        guard let assignMenu else { return }
        assignMenu.removeAllItems()
        for video in videos {
            let item = assignMenu.addItem(withTitle: displayName(for: video), action: #selector(assignVideo), keyEquivalent: "")
            item.target = self
            item.representedObject = video.path
        }
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
        if let path = UserDefaults.standard.string(forKey: "selectedVideoPath") {
            return URL(fileURLWithPath: path)
        }
        // macOS stores downloaded Aerials under the user's wallpaper cache.
        // The logical URL in com.apple.wallpaper can refer to an asset that isn't
        // directly present in /System/Library, so choose the most recently
        // downloaded local Aerial when no explicit --video path was supplied.
        let videos = availableVideos()
        return videos.first(where: { !isBundledVideo($0) }) ?? videos.first
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
        let stem = video.deletingPathExtension().lastPathComponent
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
    static let windowSize = NSSize(width: 780, height: 580)

    static func font(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom("Menlo", size: size).weight(bold ? .bold : .regular)
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
    var id: String { url.path }
}

struct PickerSection: Identifiable {
    let name: String
    let items: [PickerItem]
    var id: String { name }
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

struct PickerTile: View {
    let item: PickerItem
    let isActive: Bool
    let onPick: (URL) -> Void
    @State private var image: NSImage?
    @State private var hovering = false

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
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        if isActive {
                            Text("ACTIVE")
                                .font(PickerChrome.font(9, bold: true))
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(PickerChrome.highlight)
                                .padding(6)
                        }
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
                    .stroke(PickerChrome.accent.opacity(hovering ? 1 : (isActive ? 0.7 : 0)), lineWidth: 1.5)
            }
            .clipShape(ChamferedShape())
            .contentShape(ChamferedShape())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .task { image = await ThumbnailCache.shared.image(for: item.url) }
    }
}

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
                .background(ChamferedShape(chamfer: 8).fill(Color.black.opacity(hovering ? 0.5 : 0.35)))
                .overlay(ChamferedShape(chamfer: 8).stroke(PickerChrome.accent.opacity(hovering ? 1 : 0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct VideoPickerView: View {
    let subtitle: String
    let sections: [PickerSection]
    let activePath: String?
    let onPick: (URL) -> Void
    let onBrowse: () -> Void
    let onClose: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CHOOSE VIDEO")
                        .font(PickerChrome.font(14, bold: true))
                        .foregroundStyle(Color.white)
                    Text(subtitle)
                        .font(PickerChrome.font(10, bold: true))
                        .foregroundStyle(PickerChrome.label)
                }
                Spacer()
                PickerButton(title: "BROWSE…", action: onBrowse)
                PickerButton(title: "✕", action: onClose)
            }
            .padding(14)
            .background(Color.black.opacity(0.35))

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.name)
                                .font(PickerChrome.font(10, bold: true))
                                .tracking(1.5)
                                .foregroundStyle(PickerChrome.label)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                ForEach(section.items) { item in
                                    PickerTile(
                                        item: item,
                                        isActive: item.url.resolvingSymlinksInPath().path == activePath,
                                        onPick: onPick
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }

            Text("ESC TO CLOSE  ·  BROWSE… FOR ANY OTHER FILE")
                .font(PickerChrome.font(9))
                .foregroundStyle(PickerChrome.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.35))
        }
    }
}

final class VideoPickerPanel: NSPanel, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    private var dismissed = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(rootView: VideoPickerView) {
        let size = PickerChrome.windowSize
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .floating
        collectionBehavior = [.moveToActiveSpace]
        delegate = self

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
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

        // Bottom-right chamfer, same cut as the MetricsWidget panels (AppKit origin is bottom-left).
        let cut = PickerChrome.windowChamfer
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: size.width - cut, y: 0))
        path.addLine(to: CGPoint(x: size.width, y: cut))
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        let mask = CAShapeLayer()
        mask.path = path
        effect.layer?.mask = mask

        contentView = effect
    }

    func windowDidResignKey(_ notification: Notification) { dismiss() }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
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
