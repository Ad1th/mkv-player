import AppKit
import AVKit
import AVFoundation

let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
let ffprobePath = "/opt/homebrew/bin/ffprobe"
let videoExts: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "flv", "wmv"]
let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MKVPlayer", isDirectory: true)

func runTool(_ path: String, _ args: [String]) -> (Int32, Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, Data()) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

// Repack into MP4 so AVPlayer can play it. Copies streams AVFoundation supports, converts the rest.
func prepare(_ src: URL) -> URL? {
    let (_, data) = runTool(ffprobePath, ["-v", "error", "-show_entries",
        "stream=index,codec_type,codec_name:stream_disposition=attached_pic", "-of", "json", src.path])
    guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let streams = obj["streams"] as? [[String: Any]] else { return nil }

    var maps: [String] = [], codecs: [String] = [], subMaps: [String] = []
    var hasVideo = false, audioCount = 0
    for st in streams {
        let idx = st["index"] as? Int ?? 0
        let type = st["codec_type"] as? String ?? ""
        let codec = st["codec_name"] as? String ?? ""
        let attached = ((st["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 1
        switch type {
        case "video" where !hasVideo && !attached:
            hasVideo = true
            maps += ["-map", "0:\(idx)"]
            if codec == "hevc" { codecs += ["-c:v", "copy", "-tag:v", "hvc1"] }
            else if codec == "h264" { codecs += ["-c:v", "copy"] }
            else { codecs += ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-pix_fmt", "yuv420p"] }
        case "audio":
            maps += ["-map", "0:\(idx)"]
            if ["aac", "ac3", "eac3", "mp3", "alac"].contains(codec) {
                codecs += ["-c:a:\(audioCount)", "copy"]
            } else {
                codecs += ["-c:a:\(audioCount)", "aac", "-b:a:\(audioCount)", "256k"]
            }
            audioCount += 1
        case "subtitle" where ["subrip", "ass", "ssa", "mov_text", "webvtt", "text"].contains(codec):
            subMaps += ["-map", "0:\(idx)"]
        default: break
        }
    }
    guard hasVideo || audioCount > 0 else { return nil }

    let out = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")
    for withSubs in [true, false] where withSubs || !subMaps.isEmpty {
        var args = ["-nostdin", "-v", "error", "-y", "-i", src.path] + maps
        if withSubs && !subMaps.isEmpty { args += subMaps + ["-c:s", "mov_text"] }
        args += codecs + ["-f", "mp4", out.path]
        if runTool(ffmpegPath, args).0 == 0 { return out }
    }
    try? FileManager.default.removeItem(at: out)
    return nil
}

final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { .copy }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        guard let url = (s.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL])?.first else { return false }
        onDrop?(url)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let playerView = AVPlayerView()
    let status = NSTextField(labelWithString: "Drop a video here or press ⌘O")
    let player = AVPlayer()
    var current: URL?
    var tempFile: URL?
    var loadToken = 0

    func applicationWillFinishLaunching(_ n: Notification) {
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
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
        try? FileManager.default.removeItem(at: tempDir)
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
            let direct = ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
            let playURL = direct ? url : prepare(url)
            DispatchQueue.main.async {
                guard token == self.loadToken else {
                    if !direct, let p = playURL { try? FileManager.default.removeItem(at: p) }
                    return
                }
                guard let p = playURL else { self.status.stringValue = "Couldn't play this file"; return }
                if !direct { self.tempFile = p }
                self.status.isHidden = true
                self.player.replaceCurrentItem(with: AVPlayerItem(url: p))
                let saved = UserDefaults.standard.double(forKey: "pos:" + url.path)
                if saved > 10 { self.player.seek(to: CMTime(seconds: saved, preferredTimescale: 600)) }
                self.player.play()
            }
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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
