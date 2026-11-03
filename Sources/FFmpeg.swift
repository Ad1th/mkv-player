import Foundation

/// The fallback for files the native path can't handle (AVI, WMV, DTS audio...).
/// Only used when ffmpeg is already installed; nothing is bundled.
enum FFmpeg {
    /// Apps launched from Finder don't get the shell's PATH, so check where
    /// Homebrew (Apple Silicon and Intel), MacPorts and manual installs put it.
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                              NSHomeDirectory() + "/bin", NSHomeDirectory() + "/.local/bin"]

    static let directory: String? = searchPaths.first {
        FileManager.default.isExecutableFile(atPath: $0 + "/ffmpeg") && FileManager.default.isExecutableFile(atPath: $0 + "/ffprobe")
    }

    static var isAvailable: Bool { directory != nil }
    static var path: String { (directory ?? "") + "/ffmpeg" }
    static var probePath: String { (directory ?? "") + "/ffprobe" }

    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, Data()) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    /// Repacks into MP4, copying what AVFoundation can decode and converting the rest.
    static func convert(_ src: URL, into dir: URL) throws -> URL {
        let (_, data) = run(probePath, ["-v", "error", "-show_entries",
            "stream=index,codec_type,codec_name:stream_disposition=attached_pic", "-of", "json", src.path])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = obj["streams"] as? [[String: Any]] else { throw MediaError("ffmpeg couldn't read this file") }

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
                else if ["h264", "av1", "vp9"].contains(codec) { codecs += ["-c:v", "copy"] }
                else { codecs += ["-c:v", "h264_videotoolbox", "-b:v", "8M", "-pix_fmt", "yuv420p"] }
            case "audio":
                maps += ["-map", "0:\(idx)"]
                if ["aac", "ac3", "eac3", "mp3", "alac", "flac", "opus"].contains(codec) {
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
        guard hasVideo || audioCount > 0 else { throw MediaError("No playable streams in this file") }

        let out = dir.appendingPathComponent(UUID().uuidString + ".mp4")
        for withSubs in [true, false] where withSubs || !subMaps.isEmpty {
            var args = ["-nostdin", "-v", "error", "-y", "-i", src.path] + maps
            if withSubs && !subMaps.isEmpty { args += subMaps + ["-c:s", "mov_text"] }
            args += codecs + ["-f", "mp4", out.path]
            if run(path, args).status == 0 { return out }
        }
        try? FileManager.default.removeItem(at: out)
        throw MediaError("ffmpeg couldn't convert this file")
    }
}
