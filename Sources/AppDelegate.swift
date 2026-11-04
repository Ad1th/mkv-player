import AppKit
import AVKit
import UniformTypeIdentifiers
import AVFoundation
import VideoToolbox

let videoExts: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "flv", "wmv"]

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var window: NSWindow!
    let playerView = AVPlayerView()
    let status = NSTextField(labelWithString: "Drop a video here or press ⌘O")
    let player = AVPlayer()
    var current: URL?
    var tempFile: URL?
    var loadToken = 0
    var statusObservation: NSKeyValueObservation?
    var sizeObservation: NSKeyValueObservation?
    var seekTarget: CMTime?
    let previousButton = OverlayButton(symbol: "backward.end.fill", label: "Previous episode")
    let nextButton = OverlayButton(symbol: "forward.end.fill", label: "Next episode")
    var hideOverlay: DispatchWorkItem?
    let osd = OSD()
    /// Videos in the current file's folder, in Finder order.
    var folder: [URL] = []
    var chapters: [Chapter] = []
    var media: LoadedMedia?
    let info = InfoPanel()
    var nowPlaying: NowPlaying?
    var loopFile = false
    var loopA: Double?
    var loopB: Double?
    var loopWatcher: Any?
    let loopItem = NSMenuItem(title: "Loop", action: #selector(toggleLoop), keyEquivalent: "r")
    let floatItem = NSMenuItem(title: "Float on Top", action: #selector(toggleFloat), keyEquivalent: "t")
    /// Name of a subtitle file just added, to switch to once the new movie is ready.
    var pickNewSubtitle: String?
    let chapterMenu = NSMenu(title: "Chapters")
    let speedMenu = NSMenu(title: "Speed")
    let recentMenu = NSMenu(title: "Open Recent")
    let speeds: [Float] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    var legible: AVMediaSelectionGroup?
    var audible: AVMediaSelectionGroup?
    var lastSubtitle: AVMediaSelectionOption?
    var tracksRestored = false
    var groupsLoaded = false

    func applicationWillFinishLaunching(_ n: Notification) {
        try? FileManager.default.removeItem(at: MediaLoader.tempDir)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        buildMenu()

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MKV Player"
        window.backgroundColor = .black
        window.collectionBehavior = .fullScreenPrimary
        window.center()

        let root = PlayerContainerView(frame: window.contentView!.bounds)
        root.autoresizingMask = [.width, .height]
        root.onDrop = { [weak self] in self?.open($0) }
        root.onMouseMove = { [weak self] in self?.showOverlay() }
        root.onMouseExit = { [weak self] in self?.setOverlay(visible: false) }
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
        osd.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        root.addSubview(osd)

        for (button, side) in [(previousButton, -1), (nextButton, 1)] {
            button.alphaValue = 0
            button.isHidden = true
            button.frame.origin = NSPoint(x: side < 0 ? 20 : root.bounds.width - 64, y: root.bounds.midY - 22)
            button.autoresizingMask = side < 0 ? [.maxXMargin, .minYMargin, .maxYMargin] : [.minXMargin, .minYMargin, .maxYMargin]
            button.onClick = { [weak self] in self?.sibling(side) }
            root.addSubview(button)
        }

        window.contentView = root
        if UserDefaults.standard.bool(forKey: "floatOnTop") { window.level = .floating }
        window.makeKeyAndOrderFront(nil)

        NotificationCenter.default.addObserver(self, selector: #selector(ended(_:)),
                                               name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                               name: AVPlayerItem.mediaSelectionDidChangeNotification, object: nil)
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in
            self?.savePos()
            if let self { self.nowPlaying?.update(self.player) }
        }
        (NSApp as? PlayerApplication)?.keyHandler = { [weak self] in self?.handleKey($0) ?? false }
        nowPlaying = NowPlaying(player: player, actions: .init(
            toggle: { [weak self] in self?.togglePlay() },
            play: { [weak self] in self?.player.play() },
            pause: { [weak self] in self?.player.pause() },
            next: { [weak self] in self?.sibling(1) },
            previous: { [weak self] in self?.sibling(-1) },
            skip: { [weak self] in self?.seek(by: $0) },
            seek: { [weak self] t in
                self?.player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    if let self { self.nowPlaying?.update(self.player) }
                }
            }))
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
        fileMenu.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recentMenu
        recentMenu.delegate = self
        fileMenu.addItem(withTitle: "Open URL…", action: #selector(openURLPanel), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Add Subtitles…", action: #selector(addSubtitlesPanel), keyEquivalent: "")
        fileMenu.addItem(withTitle: "Take Snapshot", action: #selector(snapshot), keyEquivalent: "s").keyEquivalentModifierMask = []
        fileMenu.addItem(withTitle: "Next File in Folder", action: #selector(nextFile), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Previous File in Folder", action: #selector(prevFile), keyEquivalent: "p")
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let playItem = NSMenuItem(); main.addItem(playItem)
        let playMenu = NSMenu(title: "Playback")
        let chapters = playMenu.addItem(withTitle: "Chapters", action: nil, keyEquivalent: "")
        chapters.submenu = chapterMenu
        chapterMenu.delegate = self
        playMenu.addItem(withTitle: "Speed", action: nil, keyEquivalent: "").submenu = speedMenu
        loopItem.keyEquivalentModifierMask = []
        playMenu.addItem(loopItem)
        playMenu.addItem(withTitle: "A-B Loop", action: #selector(abLoop), keyEquivalent: "a").keyEquivalentModifierMask = []
        playMenu.addItem(.separator())
        speedMenu.delegate = self
        playMenu.addItem(withTitle: "Subtitles On/Off", action: #selector(toggleSubtitles), keyEquivalent: "c").keyEquivalentModifierMask = []
        playMenu.addItem(withTitle: "Next Subtitle Track", action: #selector(cycleSubtitles), keyEquivalent: "v").keyEquivalentModifierMask = []
        playMenu.addItem(withTitle: "Next Audio Track", action: #selector(cycleAudio), keyEquivalent: "b").keyEquivalentModifierMask = []
        playMenu.addItem(.separator())
        let nextChapter = playMenu.addItem(withTitle: "Next Chapter", action: #selector(nextChapter), keyEquivalent: "N")
        nextChapter.keyEquivalentModifierMask = .shift
        let prevChapter = playMenu.addItem(withTitle: "Previous Chapter", action: #selector(previousChapter), keyEquivalent: "P")
        prevChapter.keyEquivalentModifierMask = .shift
        playItem.submenu = playMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let fs = viewMenu.addItem(withTitle: "Toggle Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(withTitle: "Media Info", action: #selector(toggleInfo), keyEquivalent: "i")
        viewMenu.addItem(.separator())
        for (title, key, scale) in [("Half Size", "0", 0.5), ("Actual Size", "1", 1), ("Double Size", "2", 2), ("Fit to Screen", "3", 0)] {
            viewMenu.addItem(withTitle: title, action: #selector(sizePicked(_:)), keyEquivalent: key).representedObject = scale
        }
        viewMenu.addItem(.separator())
        floatItem.keyEquivalentModifierMask = [.command, .option]
        floatItem.state = UserDefaults.standard.bool(forKey: "floatOnTop") ? .on : .off
        viewMenu.addItem(floatItem)
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
    /// Menu shortcuts without ⌘ would fire while typing in a dialog.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        !(NSApp.modalWindow != nil && !item.keyEquivalent.isEmpty && !item.keyEquivalentModifierMask.contains(.command))
    }

    // MARK: Speed

    func speedName(_ r: Float) -> String { r == 1 ? "Normal" : String(format: "%g×", r) }
    @objc func speedPicked(_ item: NSMenuItem) { if let r = item.representedObject as? Float { setSpeed(r) } }
    @objc func faster() { changeSpeed(by: 1) }
    @objc func slower() { changeSpeed(by: -1) }

    func changeSpeed(by step: Int) {
        let i = speeds.firstIndex { $0 >= player.defaultRate } ?? speeds.count - 1
        setSpeed(speeds[min(max(i + step, 0), speeds.count - 1)])
    }

    /// defaultRate is what play() uses, so pausing and resuming keeps the speed.
    func setSpeed(_ r: Float) {
        player.defaultRate = r
        if player.rate != 0 { player.rate = r }
        osd.show(r == 1 ? "Normal speed" : "Speed \(speedName(r))")
    }

    // MARK: Audio and subtitle tracks

    func loadSelectionGroups(_ asset: AVAsset) {
        legible = nil
        audible = nil
        lastSubtitle = nil
        tracksRestored = false
        groupsLoaded = false
        let token = loadToken
        Task { @MainActor in
            let l = try? await asset.loadMediaSelectionGroup(for: .legible)
            let a = try? await asset.loadMediaSelectionGroup(for: .audible)
            guard token == loadToken else { return }
            legible = l
            audible = a
            groupsLoaded = true
            restoreTracks()
        }
    }

    // Episodes in one folder usually share their track layout, so whatever you
    // picked for the last one (Japanese audio, English subtitles, subtitles off)
    // carries over to the next.
    var tracksKey: String? { current.map { "tracks:" + $0.deletingLastPathComponent().path } }

    /// Runs once the groups are loaded and the item is ready, whichever comes
    /// last. Any earlier and AVPlayer's own automatic pick replaces ours.
    func restoreTracks() {
        guard !tracksRestored, groupsLoaded, player.currentItem?.status == .readyToPlay else { return }
        tracksRestored = true
        if let name = pickNewSubtitle, let g = legible,
           let added = g.options.last(where: { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }) {
            pickNewSubtitle = nil
            choose(added, in: g)
            return osd.show(name)
        }
        guard player.currentItem != nil, let key = tracksKey,
              let saved = UserDefaults.standard.dictionary(forKey: key) else { return }
        // Same name and position first (releases often have two "English" tracks),
        // then any track in the same language.
        func match(_ kind: String, in g: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
            let named = g.options.filter { $0.displayName == saved[kind] as? String }
            let nth = saved[kind + "Nth"] as? Int ?? 0
            return named.indices.contains(nth) ? named[nth] : named.first ?? g.options.first {
                $0.extendedLanguageTag == saved[kind + "Lang"] as? String && !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            }
        }
        if let g = audible, let o = match("audio", in: g) { choose(o, in: g) }
        if let g = legible {
            lastSubtitle = match("sub", in: g)
            if saved["subOff"] as? Bool == true { choose(nil, in: g) }
            else if let o = lastSubtitle { choose(o, in: g) }
        }
    }

    @objc func selectionChanged(_ note: Notification) {
        guard tracksRestored, let item = note.object as? AVPlayerItem, item === player.currentItem, let key = tracksKey else { return }
        var saved = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        func remember(_ o: AVMediaSelectionOption, as kind: String, in g: AVMediaSelectionGroup) {
            saved[kind] = o.displayName
            saved[kind + "Lang"] = o.extendedLanguageTag
            saved[kind + "Nth"] = g.options.filter { $0.displayName == o.displayName }.firstIndex(of: o) ?? 0
        }
        if let g = audible, let o = selected(in: g) { remember(o, as: "audio", in: g) }
        if let g = legible {
            let o = selected(in: g)
            let forced = o?.hasMediaCharacteristic(.containsOnlyForcedSubtitles) ?? true
            saved["subOff"] = forced
            if let o, !forced {
                remember(o, as: "sub", in: g)
                lastSubtitle = o
            }
        }
        UserDefaults.standard.set(saved, forKey: key)
    }

    func selected(in group: AVMediaSelectionGroup) -> AVMediaSelectionOption? {
        player.currentItem?.currentMediaSelection.selectedMediaOption(in: group)
    }

    /// While AVPlayer applies the system's caption settings it turns subtitles
    /// straight back on after you switch them off, so a manual pick ends that.
    func choose(_ option: AVMediaSelectionOption?, in group: AVMediaSelectionGroup) {
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.currentItem?.select(option, in: group)
    }

    /// C, like YouTube. Turning them back on brings back the track you had,
    /// or the first one in a language you read.
    @objc func toggleSubtitles() {
        guard player.currentItem != nil, let g = legible, !g.options.isEmpty else { return osd.show("No subtitles") }
        if let on = selected(in: g), !on.hasMediaCharacteristic(.containsOnlyForcedSubtitles) {
            lastSubtitle = on
            choose(nil, in: g)
            osd.show("Subtitles off")
            return
        }
        let full = g.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        let preferred = AVMediaSelectionGroup.mediaSelectionOptions(from: full, filteredAndSortedAccordingToPreferredLanguages: Locale.preferredLanguages)
        guard let pick = lastSubtitle ?? preferred.first ?? full.first ?? g.options.first else { return }
        choose(pick, in: g)
        osd.show(pick.displayName)
    }

    /// V and B step through every track, like VLC. Subtitles go round through "off".
    /// AVFoundation lists a "Forced" twin of every subtitle track; those are left out.
    @objc func cycleSubtitles() {
        guard player.currentItem != nil, let g = legible, !g.options.isEmpty else { return osd.show("No subtitles") }
        let tracks = g.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        let all: [AVMediaSelectionOption?] = [nil] + tracks
        let i = all.firstIndex { $0 == selected(in: g) } ?? 0
        let next = all[(i + 1) % all.count]
        choose(next, in: g)
        osd.show(next.map { "\($0.displayName)  \(i + 1)/\(tracks.count)" } ?? "Subtitles off")
    }

    @objc func cycleAudio() {
        guard player.currentItem != nil, let g = audible, g.options.count > 1 else { return osd.show("Only one audio track") }
        let i = g.options.firstIndex { $0 == selected(in: g) } ?? -1
        let next = g.options[(i + 1) % g.options.count]
        choose(next, in: g)
        osd.show("\(next.displayName)  \((i + 1) % g.options.count + 1)/\(g.options.count)")
    }

    // MARK: Chapters

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentMenu {
            menu.removeAllItems()
            for url in NSDocumentController.shared.recentDocumentURLs {
                let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(recentPicked(_:)), keyEquivalent: "")
                item.representedObject = url
                item.toolTip = url.deletingLastPathComponent().path
            }
            if menu.items.isEmpty { menu.addItem(withTitle: "No Recent Files", action: nil, keyEquivalent: "").isEnabled = false }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
                .target = NSDocumentController.shared
            return
        }
        if menu === speedMenu {
            menu.removeAllItems()
            for r in speeds {
                let item = menu.addItem(withTitle: speedName(r), action: #selector(speedPicked(_:)), keyEquivalent: "")
                item.representedObject = r
                item.state = r == player.defaultRate ? .on : .off
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Faster", action: #selector(faster), keyEquivalent: ">").keyEquivalentModifierMask = []
            menu.addItem(withTitle: "Slower", action: #selector(slower), keyEquivalent: "<").keyEquivalentModifierMask = []
            return
        }
        guard menu === chapterMenu else { return }
        menu.removeAllItems()
        let now = chapterIndex()
        for (i, c) in chapters.enumerated() {
            let item = menu.addItem(withTitle: "\(OSD.time(c.time))   \(c.title)", action: #selector(chapterPicked(_:)), keyEquivalent: "")
            item.tag = i
            item.state = i == now ? .on : .off
        }
        if chapters.isEmpty { menu.addItem(withTitle: "No Chapters", action: nil, keyEquivalent: "").isEnabled = false }
    }

    @objc func chapterPicked(_ item: NSMenuItem) { go(toChapter: item.tag) }
    @objc func nextChapter() { go(toChapter: (chapterIndex() ?? -1) + 1) }

    /// Like a DVD remote: back to the start of this chapter, or the one before
    /// if we're only a few seconds in.
    @objc func previousChapter() {
        guard let i = chapterIndex() else { return }
        go(toChapter: player.currentTime().seconds - chapters[i].time > 3 ? i : i - 1)
    }

    func chapterIndex() -> Int? {
        let now = (seekTarget ?? player.currentTime()).seconds + 0.25
        return chapters.lastIndex { $0.time <= now }
    }

    func go(toChapter i: Int) {
        guard chapters.indices.contains(i) else { return }
        seekTarget = nil
        player.seek(to: CMTime(seconds: chapters[i].time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        osd.show(chapters[i].title)
    }

    func loadChapters(_ media: LoadedMedia, asset: AVAsset) {
        chapters = media.chapters
        guard chapters.isEmpty else { return }
        let token = loadToken
        Task { @MainActor in
            let groups = (try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)) ?? []
            var found: [Chapter] = []
            for (i, g) in groups.enumerated() {
                let title = try? await AVMetadataItem.metadataItems(from: g.items, filteredByIdentifier: .commonIdentifierTitle).first?.load(.stringValue)
                found.append(Chapter(title: title ?? "Chapter \(i + 1)", time: g.timeRange.start.seconds))
            }
            if token == loadToken { chapters = found }
        }
    }

    // MARK: External subtitles

    @objc func addSubtitlesPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ExternalSubtitles.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = current?.deletingLastPathComponent()
        if panel.runModal() == .OK, let u = panel.url { addSubtitles(u) }
    }

    /// Rebuilds the movie with the new file as one more subtitle track and
    /// carries on from the same spot with it switched on.
    func addSubtitles(_ file: URL) {
        guard var media = self.media, let video = current, player.currentItem != nil else { return osd.show("Open a video first") }
        guard !media.subtitleFiles.contains(file) else { return }
        let time = player.currentTime()
        let token = loadToken
        Task { @MainActor in
            do {
                try await media.attach(media.subtitleFiles + [file], video: video)
                guard token == loadToken else { return }
                media.notes = []
                pickNewSubtitle = file.lastPathComponent
                play(media, from: video, at: time)
            } catch {
                osd.show("\(error)")
            }
        }
    }

    /// Takes a link from the clipboard if there is one.
    @objc func openURLPanel() {
        let alert = NSAlert()
        alert.messageText = "Open URL"
        alert.informativeText = "A direct link to a video, or an HLS stream (.m3u8)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://"
        if let copied = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let u = URL(string: copied), u.scheme == "http" || u.scheme == "https" {
            field.stringValue = copied
        }
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let u = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), u.scheme != nil else { return }
        open(u)
    }

    @objc func recentPicked(_ item: NSMenuItem) { if let u = item.representedObject as? URL { open(u) } }

    @objc func nextFile() { sibling(1) }
    @objc func prevFile() { sibling(-1) }

    func open(_ url: URL) {
        if ExternalSubtitles.extensions.contains(url.pathExtension.lowercased()) { return addSubtitles(url) }
        savePos()
        current = url
        loadToken += 1
        let token = loadToken
        player.replaceCurrentItem(with: nil)
        chapters = []
        clearABLoop()
        if let t = tempFile { try? FileManager.default.removeItem(at: t); tempFile = nil }
        window.title = url.lastPathComponent
        status.stringValue = "Preparing…"
        status.isHidden = false
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        scanFolder(of: url)

        Task.detached(priority: .userInitiated) {
            let loaded: Result<LoadedMedia, Error>
            do { loaded = .success(try await MediaLoader.loadWithSidecars(url)) } catch { loaded = .failure(error) }
            await MainActor.run {
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

    func play(_ media: LoadedMedia, from url: URL, at time: CMTime? = nil) {
        self.media = media
        if media.isTemporary { tempFile = media.url }
        status.isHidden = true
        if !media.notes.isEmpty { osd.show(media.notes.joined(separator: "\n"), for: 5) }

        let item = AVPlayerItem(url: media.playable)
        loadChapters(media, asset: item.asset)
        loadSelectionGroups(item.asset)
        // If AVFoundation chokes on our remux, ffmpeg gets a turn before we give up.
        statusObservation = item.observe(\.status) { [weak self] item, _ in
            switch item.status {
            case .failed: DispatchQueue.main.async { self?.playbackFailed(url, media) }
            case .readyToPlay: DispatchQueue.main.async { self?.restoreTracks() }
            default: break
            }
        }
        sizeObservation = item.observe(\.presentationSize) { [weak self] item, _ in
            let size = item.presentationSize
            DispatchQueue.main.async { self?.fitWindow(to: size) }
        }
        // With choices saved for this folder we pick the tracks ourselves; otherwise
        // AVPlayer would switch subtitles back on to match the system settings.
        player.appliesMediaSelectionCriteriaAutomatically = tracksKey.flatMap { UserDefaults.standard.dictionary(forKey: $0) } == nil
        player.replaceCurrentItem(with: item)
        if VolumeBoost.gain > 1 { attachBoost() }
        let saved = UserDefaults.standard.double(forKey: "pos:" + url.path)
        if let time { player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) }
        else if saved > 10 { player.seek(to: CMTime(seconds: saved, preferredTimescale: 600)) }
        player.play()
        nowPlaying?.title = url.deletingPathExtension().lastPathComponent
        nowPlaying?.update(player)
        if info.isVisible { info.update(url, media, item.asset, chapters: media.chapters.count) }
    }

    /// Picture-in-picture without the picture-in-picture: stays above other windows.
    @objc func toggleFloat() {
        let on = window.level != .floating
        window.level = on ? .floating : .normal
        floatItem.state = on ? .on : .off
        UserDefaults.standard.set(on, forKey: "floatOnTop")
    }

    /// Half, actual and double size are in video pixels per point; 0 fills the screen.
    @objc func sizePicked(_ item: NSMenuItem) {
        guard let size = player.currentItem?.presentationSize, size.width > 0, let scale = item.representedObject as? Double else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        fitWindow(to: size, width: scale > 0 ? size.width * scale : (window.screen ?? NSScreen.main)?.visibleFrame.width)
    }

    /// Match the window to the video's shape (keeping its width unless told
    /// otherwise) so there are no black bars, and keep that shape while resizing.
    func fitWindow(to size: CGSize, width: CGFloat? = nil) {
        guard size.width > 0, size.height > 0, !window.styleMask.contains(.fullScreen),
              let screen = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        window.contentAspectRatio = size
        let content = window.contentRect(forFrameRect: window.frame)
        let chrome = window.frame.height - content.height
        var w = width ?? content.width
        var h = w * size.height / size.width
        if h > screen.height - chrome { h = screen.height - chrome; w = h * size.width / size.height }
        if w > screen.width { w = screen.width; h = w * size.height / size.width }
        var frame = window.frameRect(forContentRect: NSRect(x: content.midX - w / 2, y: content.midY - h / 2, width: w, height: h))
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        window.setFrame(frame.integral, display: true, animate: window.isVisible)
    }

    func playbackFailed(_ url: URL, _ media: LoadedMedia) {
        guard url == current else { return }
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
        guard !media.usedFFmpeg, url.isFileURL, FFmpeg.isAvailable else {
            status.stringValue = url.isFileURL ? "Couldn't play this file" : "Couldn't play this link"
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

    func savePos() {
        guard let c = current, player.currentItem != nil else { return }
        let t = player.currentTime().seconds
        if t.isFinite && t > 0 { UserDefaults.standard.set(t, forKey: "pos:" + c.path) }
    }

    @objc func ended(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === player.currentItem, let c = current else { return }
        if loopFile {
            player.seek(to: .zero)
            return player.play()
        }
        UserDefaults.standard.removeObject(forKey: "pos:" + c.path)
        sibling(1, fromEnd: true)
    }

    @objc func toggleInfo() {
        info.toggle(current, media, player.currentItem?.asset, chapters: chapters.count, near: window)
    }

    // MARK: Snapshot

    /// The exact frame on screen at full resolution, saved to ~/Pictures/MKV Player
    /// and copied so it can be pasted straight into a chat.
    @objc func snapshot() {
        guard let item = player.currentItem, let video = current else { return }
        let time = item.currentTime()
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/MKV Player")
        let name = "\(video.deletingPathExtension().lastPathComponent) \(OSD.time(time.seconds).replacingOccurrences(of: ":", with: "."))"
        Task { @MainActor in
            do {
                let image = try await generator.image(at: time).image
                let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) ?? Data()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try png.write(to: dir.appendingPathComponent(name + ".png"))
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(png, forType: .png)
                osd.show("Snapshot saved to Pictures and copied")
            } catch {
                osd.show("Couldn't take a snapshot")
            }
        }
    }

    // MARK: Loops

    /// R, like the repeat button on a CD player.
    @objc func toggleLoop() {
        loopFile.toggle()
        loopItem.state = loopFile ? .on : .off
        osd.show(loopFile ? "Loop on" : "Loop off")
    }

    /// A once marks the start, again marks the end and starts looping, a third
    /// time turns it off. Same single button as VLC.
    @objc func abLoop() {
        guard player.currentItem != nil else { return }
        let now = player.currentTime().seconds
        if let a = loopA, loopB == nil, now > a + 0.2 {
            loopB = now
            osd.show("Looping \(OSD.time(a)) – \(OSD.time(now))", for: 2)
            player.seek(to: CMTime(seconds: a, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            loopWatcher = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
                guard let self, let a = self.loopA, let b = self.loopB, t.seconds >= b, self.seekTarget == nil else { return }
                self.player.seek(to: CMTime(seconds: a, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        } else if loopA == nil {
            loopA = now
            osd.show("Loop from \(OSD.time(now)), press A at the end", for: 2)
        } else {
            clearABLoop()
            osd.show("A-B loop off")
        }
    }

    func clearABLoop() {
        if let w = loopWatcher { player.removeTimeObserver(w) }
        loopWatcher = nil
        loopA = nil
        loopB = nil
    }

    /// Listed once per file and off the main thread: the first look inside
    /// ~/Downloads waits on the privacy prompt, and a network share can take
    /// seconds. The old list stays until the new one arrives.
    func scanFolder(of url: URL) {
        let dir = url.deletingLastPathComponent()
        if folder.first?.deletingLastPathComponent() != dir { folder = [] }
        DispatchQueue.global(qos: .utility).async {
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { videoExts.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            DispatchQueue.main.async {
                guard self.current?.deletingLastPathComponent() == dir else { return }
                self.folder = files
            }
        }
    }

    /// The file `offset` places away from the current one in its folder.
    func neighbour(_ offset: Int) -> URL? {
        guard let c = current, let i = folder.firstIndex(where: { $0.lastPathComponent == c.lastPathComponent }) else { return nil }
        return folder.indices.contains(i + offset) ? folder[i + offset] : nil
    }

    func sibling(_ d: Int, fromEnd: Bool = false) {
        guard let target = neighbour(d) else { return }
        if fromEnd { current = nil }
        open(target)
    }

    // MARK: Episode buttons

    func showOverlay() {
        setOverlay(visible: true)
        hideOverlay?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.setOverlay(visible: false) }
        hideOverlay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    func setOverlay(visible: Bool) {
        let previous = player.currentItem != nil ? neighbour(-1) : nil
        let next = player.currentItem != nil ? neighbour(1) : nil
        previousButton.toolTip = previous?.deletingPathExtension().lastPathComponent
        nextButton.toolTip = next?.deletingPathExtension().lastPathComponent
        for (button, target) in [(previousButton, previous), (nextButton, next)] {
            let show = visible && target != nil
            if show { button.isHidden = false }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = show ? 0.15 : 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                button.animator().alphaValue = show ? 1 : 0
            }, completionHandler: { if !show && button.alphaValue == 0 { button.isHidden = true } })
        }
    }

    func togglePlay() {
        guard let item = player.currentItem else { return }
        if player.timeControlStatus == .paused {
            if item.duration.isNumeric, item.currentTime().seconds >= item.duration.seconds - 0.25 {
                player.seek(to: .zero)
            }
            player.play()
        } else {
            player.pause()
        }
    }

    /// Relative seek. Holding an arrow key fires faster than seeks finish, so each
    /// press builds on the pending target instead of where playback currently is.
    func seek(by seconds: Double) {
        guard let item = player.currentItem else { return }
        var t = (seekTarget ?? player.currentTime()).seconds + seconds
        if item.duration.isNumeric { t = min(t, item.duration.seconds - 0.1) }
        let target = CMTime(seconds: max(0, t), preferredTimescale: 600)
        seekTarget = target
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            if finished { self?.seekTarget = nil }
        }
        osd.show("\(seconds < 0 ? "−" : "+")\(Int(abs(seconds))) s  ·  \(OSD.time(target.seconds))")
    }

    /// 0 to 2. Past 1 the player stays at full volume and the boost does the rest.
    var volumeLevel: Float { player.volume * VolumeBoost.gain }

    func changeVolume(by delta: Float) {
        player.isMuted = false
        let level = min(2, max(0, ((volumeLevel + delta) * 20).rounded() / 20))
        if level > 1 {
            player.volume = 1
            VolumeBoost.gain = level
            attachBoost()
        } else {
            player.volume = level
            VolumeBoost.gain = 1
        }
        osd.show("Volume \(Int((level * 100).rounded()))%")
    }

    /// Only once the volume first goes past 100%, so normal playback never runs through a tap.
    func attachBoost() {
        guard let item = player.currentItem, item.audioMix == nil else { return }
        Task { @MainActor in
            if item.audioMix == nil { item.audioMix = await VolumeBoost.audioMix(for: item.asset) }
        }
    }

    func toggleMute() {
        player.isMuted.toggle()
        osd.show(player.isMuted ? "Muted" : "Volume \(Int((volumeLevel * 100).rounded()))%")
    }

    /// 0-9 jump to 0%-90%, like YouTube. End goes to just before the last frame.
    func jump(toFraction f: Double) {
        guard let item = player.currentItem, item.duration.isNumeric else { return }
        seekTarget = nil
        let t = max(0, min(item.duration.seconds * f, item.duration.seconds - 0.5))
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        osd.show("\(OSD.time(t)) / \(OSD.time(item.duration.seconds))")
    }

    func step(_ frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
    }

    /// Returns true when the key is one of ours, for key down and key up alike, so
    /// AVPlayerView never gets a second go at it.
    func handleKey(_ e: NSEvent) -> Bool {
        guard NSApp.modalWindow == nil, e.window === window, !e.modifierFlags.contains(.command),
              !(window.firstResponder is NSText), let action = action(for: e) else { return false }
        if e.type == .keyDown && (!e.isARepeat || action.repeats) { action.run() }
        return true
    }

    /// YouTube's layout: space/K play-pause, left/right 5 s, J/L 10 s, up/down volume,
    /// 0-9 jump, comma/period step a frame.
    func action(for e: NSEvent) -> (repeats: Bool, run: () -> Void)? {
        switch e.keyCode {
        case 49: return (false, togglePlay)
        case 123: return (true, { self.seek(by: -5) })
        case 124: return (true, { self.seek(by: 5) })
        case 126: return (true, { self.changeVolume(by: 0.05) })
        case 125: return (true, { self.changeVolume(by: -0.05) })
        case 115: return (false, { self.jump(toFraction: 0) })     // home
        case 119: return (false, { self.jump(toFraction: 1) })     // end
        case 53 where window.styleMask.contains(.fullScreen): return (false, { self.window.toggleFullScreen(nil) })
        default: break
        }
        if let c = e.charactersIgnoringModifiers, c.count == 1, let digit = Int(c) {
            return (false, { self.jump(toFraction: Double(digit) / 10) })
        }
        switch e.charactersIgnoringModifiers {
        case ">": return (true, faster)
        case "<": return (true, slower)
        case "N": return (false, nextChapter)
        case "P": return (false, previousChapter)
        default: break
        }
        switch e.charactersIgnoringModifiers?.lowercased() {
        case "k": return (false, togglePlay)
        case "j": return (true, { self.seek(by: -10) })
        case "l": return (true, { self.seek(by: 10) })
        case "f": return (false, { self.window.toggleFullScreen(nil) })
        case "m": return (false, toggleMute)
        case "s": return (false, snapshot)
        case "r": return (false, toggleLoop)
        case "a": return (false, abLoop)
        case "c": return (false, toggleSubtitles)
        case "v": return (false, cycleSubtitles)
        case "b": return (false, cycleAudio)
        case ",": return (true, { self.step(-1) })
        case ".": return (true, { self.step(1) })
        case "n": return (false, { self.sibling(1) })
        case "p": return (false, { self.sibling(-1) })
        default: return nil
        }
    }
}
