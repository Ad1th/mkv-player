import AVFoundation

/// What the player gets back after opening a file.
struct LoadedMedia {
    var url: URL
    var isTemporary: Bool
    var usedFFmpeg = false
    /// Short notes for the viewer, like "DTS audio isn't supported".
    var notes: [String] = []
    var subtitles: [MatroskaRemuxer.Result.Subtitle] = []
    var chapters: [Chapter] = []
}

/// Decides how a file gets played:
/// Matroska and WebM go through the native remuxer, things AVFoundation already
/// understands play as they are, and everything else needs ffmpeg.
enum MediaLoader {
    static let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MKVPlayer", isDirectory: true)
    static let nativeExtensions: Set<String> = ["mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav", "aif", "aiff", "caf", "3gp", "flac"]

    static func load(_ url: URL) throws -> LoadedMedia {
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if isMatroska(url) { return try loadMatroska(url) }
        if nativeExtensions.contains(url.pathExtension.lowercased()) || AVURLAsset(url: url).isPlayable {
            return LoadedMedia(url: url, isTemporary: false)
        }
        return try viaFFmpeg(url)
    }

    static func viaFFmpeg(_ url: URL) throws -> LoadedMedia {
        guard FFmpeg.isAvailable else {
            throw MediaError("macOS can't play .\(url.pathExtension) files by itself. Install ffmpeg (brew install ffmpeg) and MKV Player will use it.")
        }
        return LoadedMedia(url: try FFmpeg.convert(url, into: tempDir), isTemporary: true, usedFFmpeg: true)
    }

    static func isMatroska(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return h.readData(ofLength: 4) == Data([0x1A, 0x45, 0xDF, 0xA3])
    }

    static func loadMatroska(_ url: URL) throws -> LoadedMedia {
        let mkv = try MatroskaFile(path: url.path)
        let out = tempDir.appendingPathComponent(UUID().uuidString + ".mov")
        let result: MatroskaRemuxer.Result
        do {
            result = try MatroskaRemuxer(mkv: mkv).remux(to: out)
        } catch {
            if FFmpeg.isAvailable { return try viaFFmpeg(url) }
            throw error
        }

        // A file whose only audio is DTS plays silent natively. If ffmpeg is around,
        // let it convert that track instead.
        let lostVideo = !result.hasVideo && mkv.tracks.contains { $0.kind == .video }
        let lostAudio = !result.hasAudio && mkv.tracks.contains { $0.kind == .audio }
        if (lostVideo || lostAudio) && FFmpeg.isAvailable, let converted = try? viaFFmpeg(url) {
            try? FileManager.default.removeItem(at: out)
            return converted
        }

        var media = LoadedMedia(url: out, isTemporary: true, subtitles: result.subtitles, chapters: result.chapters)
        media.notes = result.skipped.filter { !$0.contains("subtitles") || !result.hasVideo }.map { "\($0) isn't supported" }
        if lostVideo || lostAudio { media.notes.append("Install ffmpeg to play the rest") }
        return media
    }
}
