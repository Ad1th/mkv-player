import AppKit
import AVFoundation

/// ⌘I: what's in the file. Codecs, sizes, rates and tracks, as plain text you can copy.
final class InfoPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                        styleMask: [.titled, .closable, .utilityWindow, .hudWindow], backing: .buffered, defer: true)
    let text = NSTextField(wrappingLabelWithString: "")
    private var token = 0

    init() {
        panel.title = "Media Info"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.textColor = .white
        text.isSelectable = true
        text.frame = NSRect(x: 16, y: 14, width: 388, height: 172)
        text.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(text)
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(_ file: URL?, _ media: LoadedMedia?, _ asset: AVAsset?, chapters: Int, near window: NSWindow) {
        if panel.isVisible { return panel.orderOut(nil) }
        if panel.frame.origin == .zero {
            panel.setFrameTopLeftPoint(NSPoint(x: window.frame.maxX + 12, y: window.frame.maxY))
        }
        update(file, media, asset, chapters: chapters)
        panel.orderFront(nil)
    }

    func update(_ file: URL?, _ media: LoadedMedia?, _ asset: AVAsset?, chapters: Int) {
        token += 1
        let mine = token
        guard let file, let asset else { return show("Nothing playing") }
        Task { @MainActor in
            let body = await Self.describe(file, media, asset, chapters: chapters)
            if mine == token { show(body) }
        }
    }

    private func show(_ s: String) {
        // Wrapped lines line up under the values, not under the labels.
        let font = text.font ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
        let style = NSMutableParagraphStyle()
        style.headIndent = ("Subtitles  " as NSString).size(withAttributes: [.font: font]).width
        text.attributedStringValue = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: style])
        let height = text.sizeThatFits(NSSize(width: 388, height: 2000)).height
        var frame = panel.frame
        let content = panel.contentRect(forFrameRect: frame)
        let newHeight = height + 28 + (frame.height - content.height)
        frame.origin.y += frame.height - newHeight
        frame.size.height = newHeight
        panel.setFrame(frame, display: true)
    }

    static let containers = ["mkv": "Matroska", "webm": "WebM", "mp4": "MPEG-4", "m4v": "MPEG-4", "mov": "QuickTime",
                             "avi": "AVI", "ts": "MPEG-TS", "flv": "Flash Video", "wmv": "Windows Media"]
    static let codecs = ["hvc1": "HEVC", "hev1": "HEVC", "avc1": "H.264", "avc3": "H.264", "av01": "AV1", "vp09": "VP9",
                         "mp4a": "AAC", "ac-3": "AC-3", "ec-3": "E-AC-3", ".mp3": "MP3", ".mp2": "MP2", "fLaC": "FLAC",
                         "Opus": "Opus", "alac": "ALAC", "ipcm": "PCM", "fpcm": "PCM", "lpcm": "PCM", "sowt": "PCM",
                         "tx3g": "Text", "wvtt": "WebVTT", "c608": "CEA-608", "apcn": "ProRes", "apch": "ProRes",
                         // Audio formats come back as Core Audio's codes instead.
                         "aac ": "AAC", "aach": "HE-AAC", "flac": "FLAC", "opus": "Opus"]

    @MainActor static func describe(_ file: URL, _ media: LoadedMedia?, _ asset: AVAsset, chapters: Int) async -> String {
        var lines = [file.lastPathComponent]
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let container = containers[file.pathExtension.lowercased()] ?? file.pathExtension.uppercased()
        lines.append([container, ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file),
                      duration.isFinite ? OSD.time(duration) : nil].compactMap { $0 }.joined(separator: " · "))
        if media?.usedFFmpeg == true { lines.append("Converted with ffmpeg") }
        lines.append("")

        var subtitles: [String] = []
        for track in (try? await asset.load(.tracks)) ?? [] {
            let format = (try? await track.load(.formatDescriptions))?.first
            let fourcc = format.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
            let codec = codecs[fourcc] ?? fourcc
            let tag = try? await track.load(.extendedLanguageTag)
            let code = try? await track.load(.languageCode)
            let language = (tag ?? nil) ?? (code ?? nil)
            let languageName = language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
            switch track.mediaType {
            case .video:
                let size = (try? await track.load(.naturalSize)) ?? .zero
                let fps = (try? await track.load(.nominalFrameRate)) ?? 0
                let rate = (try? await track.load(.estimatedDataRate)) ?? 0
                lines.append("Video      " + [codec, "\(Int(size.width))×\(Int(size.height))",
                                              fps > 0 ? (abs(fps - fps.rounded()) < 0.01 ? "\(Int(fps.rounded())) fps" : String(format: "%.3f fps", fps)) : nil, bitrate(rate)].compactMap { $0 }.joined(separator: " · "))
            case .audio:
                let asbd = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let rate = (try? await track.load(.estimatedDataRate)) ?? 0
                lines.append("Audio      " + [codec, asbd.map { "\($0.mChannelsPerFrame) ch" },
                                              asbd.map { String(format: "%g kHz", $0.mSampleRate / 1000) },
                                              bitrate(rate), languageName].compactMap { $0 }.joined(separator: " · "))
            case .subtitle, .text, .closedCaption:
                subtitles.append(languageName ?? codec)
            default: break
            }
        }
        if !subtitles.isEmpty {
            // "English ×4, Arabic ×4" reads better than twenty-two names in a row.
            var counts: [(String, Int)] = []
            for s in subtitles {
                if let i = counts.firstIndex(where: { $0.0 == s }) { counts[i].1 += 1 } else { counts.append((s, 1)) }
            }
            lines.append("Subtitles  " + counts.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 }.joined(separator: ", "))
        }
        if chapters > 0 { lines.append("Chapters   \(chapters)") }
        if let notes = media?.notes, !notes.isEmpty { lines += [""] + notes }
        return lines.joined(separator: "\n")
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func bitrate(_ bitsPerSecond: Float) -> String? {
        guard bitsPerSecond > 0 else { return nil }
        return bitsPerSecond >= 1_000_000 ? String(format: "%.1f Mb/s", bitsPerSecond / 1e6) : "\(Int(bitsPerSecond / 1000)) kb/s"
    }
}
