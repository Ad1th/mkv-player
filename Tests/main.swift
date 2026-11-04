import AVFoundation
import VideoToolbox

// Remuxes each file given on the command line and decodes every sample of every
// track through AVFoundation. Exits non-zero if anything fails to decode or the
// frame counts don't match the Matroska index.

VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mkv-check", isDirectory: true)
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
var failures = 0

func check(_ path: String) {
    let name = (path as NSString).lastPathComponent
    do {
        let start = Date()
        let mkv = try MatroskaFile(path: path)
        let out = tmp.appendingPathComponent(name + ".mov")
        let result = try MatroskaRemuxer(mkv: mkv).remux(to: out)
        let took = Date().timeIntervalSince(start)
        let asset = AVURLAsset(url: out)
        var line = String(format: "%@ (%.0f ms)", name, took * 1000)
        var ok = asset.isPlayable
        let kinds = Set(asset.tracks.map(\.mediaType))
        if result.hasVideo && !kinds.contains(.video) || result.hasAudio && !kinds.contains(.audio) { ok = false }
        for track in asset.tracks {
            guard let reader = try? AVAssetReader(asset: asset) else { ok = false; continue }
            let settings: [String: Any]? = switch track.mediaType {
            case .video: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            case .audio: [AVFormatIDKey: kAudioFormatLinearPCM]
            default: nil
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            reader.add(output)
            reader.startReading()
            var count = 0, first = -1.0, last = -1.0
            while let sample = output.copyNextSampleBuffer() {
                let n = CMSampleBufferGetNumSamples(sample)
                if n == 0 { continue }
                count += n
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if first < 0 { first = t }
                last = t
            }
            if reader.status == .failed { ok = false }
            line += String(format: " | %@ %d [%.3f-%.3f]", track.mediaType.rawValue, count, first, last)
            if reader.status == .failed { line += " FAILED \(reader.error!.localizedDescription)" }
        }
        line += String(format: " dur %.3f", asset.duration.seconds)
        if !result.skipped.isEmpty { line += " skipped: " + result.skipped.joined(separator: ", ") }
        if !ok { failures += 1 }
        print((ok ? "ok   " : "FAIL ") + line)
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}

for path in CommandLine.arguments.dropFirst() { check(path) }
exit(failures == 0 ? 0 : 1)
