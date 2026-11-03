import AppKit
import AVKit
import AVFoundation

let videoExts: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "flv", "wmv"]

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let playerView = AVPlayerView()
    let status = NSTextField(labelWithString: "Drop a video here or press ⌘O")
    let player = AVPlayer()
    var current: URL?
    var tempFile: URL?
    var loadToken = 0
    var statusObservation: NSKeyValueObservation?

    func applicationWillFinishLaunching(_ n: Notification) {
        try? FileManager.default.removeItem(at: MediaLoader.tempDir)
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MKV Player"
        window.backgroundColor = .black
        window.collectionBehavior = .fullScreenPrimary
        window.center()

        let root = DropView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        root.onDrop = { [weak self] in self?.open($0) }
        playerView.frame = root.bounds
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.player = player
        root.addSubview(playerView)

        status.textColor = .white
        status.font = .systemFont(ofSize: 18, weight: .medium)
        status.alignment = .center
        status.frame = NSRect(x: 0, y: root.bounds.midY - 15, width: root.bounds.width, height: 30)
        status.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        root.addSubview(status)

        window.contentView = root
        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(self, selector: #selector(ended(_:)),
                                               name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
            self?.savePos()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in self?.key(e) ?? e }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            if self?.current == nil { self?.openPanel() }
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) { if let u = urls.first { open(u) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        savePos()
        try? FileManager.default.removeItem(at: MediaLoader.tempDir)
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit MKV Player", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openPanel), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Next File in Folder", action: #selector(nextFile), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Previous File in Folder", action: #selector(prevFile), keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = viewMenu
        NSApp.mainMenu = main
    }

    @objc func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let u = panel.url { open(u) }
    }
    @objc func nextFile() { sibling(1) }
    @objc func prevFile() { sibling(-1) }

    func open(_ url: URL) {
        savePos()
        current = url
        loadToken += 1
        let token = loadToken
        player.replaceCurrentItem(with: nil)
        if let t = tempFile { try? FileManager.default.removeItem(at: t); tempFile = nil }
        window.title = url.lastPathComponent
        status.stringValue = "Preparing…"
        status.isHidden = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)

        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = Result { try MediaLoader.load(url) }
            DispatchQueue.main.async {
                guard token == self.loadToken else {
                    if case .success(let m) = loaded, m.isTemporary { try? FileManager.default.removeItem(at: m.url) }
                    return
                }
                switch loaded {
                case .success(let media): self.play(media, from: url)
                case .failure(let error): self.status.stringValue = "\(error)"
                }
            }
        }
    }

    func play(_ media: LoadedMedia, from url: URL) {
        if media.isTemporary { tempFile = media.url }
        status.isHidden = true
        if !media.notes.isEmpty { flash(media.notes.joined(separator: "\n")) }

        let item = AVPlayerItem(url: media.url)
        // If AVFoundation chokes on our remux, ffmpeg gets a turn before we give up.
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            guard item.status == .failed else { return }
            DispatchQueue.main.async { self?.playbackFailed(url, media) }
        }
        player.replaceCurrentItem(with: item)
        let saved = UserDefaults.standard.double(forKey: "pos:" + url.path)
        if saved > 10 { player.seek(to: CMTime(seconds: saved, preferredTimescale: 600)) }
        player.play()
    }

    func playbackFailed(_ url: URL, _ media: LoadedMedia) {
        guard url == current else { return }
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        guard !media.usedFFmpeg, FFmpeg.isAvailable else {
            status.stringValue = "Couldn't play this file"
            status.isHidden = false
            return
        }
        status.stringValue = "Converting with ffmpeg…"
        status.isHidden = false
        let token = loadToken
        DispatchQueue.global(qos: .userInitiated).async {
            let converted = Result { try MediaLoader.viaFFmpeg(url) }
            DispatchQueue.main.async {
                guard token == self.loadToken else { return }
                switch converted {
                case .success(let m): self.play(m, from: url)
                case .failure(let error): self.status.stringValue = "\(error)"
                }
            }
        }
    }

    /// Shows a message over the video for a few seconds.
    func flash(_ message: String) {
        status.stringValue = message
        status.isHidden = false
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.status.stringValue == shown && self?.player.currentItem != nil { self?.status.isHidden = true }
        }
    }

    func savePos() {
        guard let c = current, player.currentItem != nil else { return }
        let t = player.currentTime().seconds
        if t.isFinite && t > 0 { UserDefaults.standard.set(t, forKey: "pos:" + c.path) }
    }

    @objc func ended(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === player.currentItem, let c = current else { return }
        UserDefaults.standard.removeObject(forKey: "pos:" + c.path)
        sibling(1, fromEnd: true)
    }

    func sibling(_ d: Int, fromEnd: Bool = false) {
        guard let c = current else { return }
        if fromEnd { current = nil }
        let files = ((try? FileManager.default.contentsOfDirectory(at: c.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [])
            .filter { videoExts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let i = files.firstIndex(where: { $0.lastPathComponent == c.lastPathComponent }) else { return }
        let j = i + d
        if j >= 0 && j < files.count { open(files[j]) } else { current = c }
    }

    func seek(_ s: Double) {
        guard player.currentItem != nil else { return }
        let t = max(0, player.currentTime().seconds + s)
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func key(_ e: NSEvent) -> NSEvent? {
        guard e.window === window, !e.modifierFlags.contains(.command) else { return e }
        switch e.keyCode {
        case 49: if player.rate == 0 { player.play() } else { player.pause() }; return nil  // space
        case 123: seek(-10); return nil   // left
        case 124: seek(10); return nil    // right
        case 125: seek(-60); return nil   // down
        case 126: seek(60); return nil    // up
        case 53:                          // esc
            if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil); return nil }
            return e
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "f": window.toggleFullScreen(nil); return nil
        case "m": player.isMuted.toggle(); return nil
        case "n": sibling(1); return nil
        case "p": sibling(-1); return nil
        default: return e
        }
    }
}
