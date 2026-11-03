import Foundation

let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
let ffprobePath = "/opt/homebrew/bin/ffprobe"

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
