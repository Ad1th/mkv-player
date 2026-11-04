import Foundation

struct Chapter {
    var title: String
    var time: Double
}

/// Turns a parsed Matroska file into a QuickTime movie AVPlayer can open.
struct MatroskaRemuxer {
    struct Result {
        var hasVideo = false
        var hasAudio = false
        /// Tracks we had to leave out, like "DTS audio (eng)".
        var skipped: [String] = []
        var chapters: [Chapter] = []
        var subtitles: [Subtitle] = []

        struct Subtitle {
            var language: String
            var name: String
            var forced: Bool
            var isDefault: Bool
        }
    }

    let mkv: MatroskaFile
    /// Write a self-contained movie instead of one that references the MKV.
    var copyFrames = false

    private var ticksPerSecond: Double { 1e9 / Double(mkv.timestampScale) }
    private func nanoseconds(_ ticks: Int64) -> Double { Double(ticks) * Double(mkv.timestampScale) }

    func remux(to url: URL) throws -> Result {
        var result = Result()
        var tracks: [MovieTrack] = []

        let video = mkv.tracks.filter { $0.kind == .video && $0.isEnabled && (mkv.frames[$0.number]?.count ?? 0) > 0 }
        let origin = startTime()

        for t in video {
            if result.hasVideo {
                result.skipped.append("extra video track")
                continue
            }
            if let track = videoTrack(t, origin: origin) {
                tracks.append(track)
                result.hasVideo = true
            } else {
                result.skipped.append("\(codecName(t)) video")
            }
        }

        let audio = mkv.tracks.filter { $0.kind == .audio && (mkv.frames[$0.number]?.count ?? 0) > 0 }
        // Play the track the file marks as default first; the rest go in the audio menu.
        let ordered = audio.filter { $0.isDefault && $0.isEnabled } + audio.filter { !($0.isDefault && $0.isEnabled) }
        for t in ordered {
            if let track = audioTrack(t, origin: origin) {
                track.isEnabled = !result.hasAudio
                track.alternateGroup = 1
                tracks.append(track)
                result.hasAudio = true
            } else {
                result.skipped.append("\(codecName(t)) audio (\(t.language))")
            }
        }

        for t in mkv.tracks where t.kind == .subtitle {
            guard let frames = mkv.frames[t.number] else { continue }
            guard let cues = Subtitles.cues(t, frames, file: mkv.file, timestampScale: mkv.timestampScale, origin: origin) else {
                result.skipped.append("\(codecName(t)) subtitles (\(t.language))")
                continue
            }
            if let track = Subtitles.track(cues, language: MovieLanguage.code(t), name: t.name) {
                tracks.append(track)
                result.subtitles.append(Result.Subtitle(language: track.language, name: t.name, forced: t.isForced, isDefault: t.isDefault))
            }
        }

        let originNs = nanoseconds(origin)
        result.chapters = mkv.chapters.enumerated().map { i, c in
            Chapter(title: c.title.isEmpty ? "Chapter \(i + 1)" : c.title, time: max(0, (Double(c.start) - originNs) / 1e9))
        }

        guard !tracks.isEmpty else { throw MediaError("Nothing in this file can be played natively") }
        try MovieWriter.write(tracks, to: url)
        return result
    }

    /// The earliest timestamp of any audio or video frame becomes zero.
    private func startTime() -> Int64 {
        let firsts = mkv.tracks
            .filter { $0.kind == .video || $0.kind == .audio }
            .compactMap { t -> Int64? in
                guard let f = mkv.frames[t.number], f.count > 0 else { return nil }
                return f.times.prefix(64).min()
            }
        return firsts.min() ?? 0
    }

    // MARK: Video

    private func videoTrack(_ t: MatroskaTrack, origin: Int64) -> MovieTrack? {
        guard let frames = mkv.frames[t.number], t.compression == nil, !t.encrypted else { return nil }

        var width = t.pixelWidth, height = t.pixelHeight
        if t.displayWidth > 0, t.displayHeight > 0, t.displayUnit == 0 || t.displayUnit == 3 {
            width = Int((Double(t.pixelHeight) * Double(t.displayWidth) / Double(t.displayHeight)).rounded())
            height = t.pixelHeight
        }
        let firstKey = frames.keyframes.firstIndex(of: true) ?? 0
        let first = t.strippedHeader + mkv.file.data(frames.offsets[firstKey], min(frames.sizes[firstKey], 64))
        guard let entry = SampleEntries.video(t, width: width, height: height, firstFrame: first) else { return nil }

        let (timescale, frameDuration, pts) = videoTimestamps(t, frames, origin: origin)
        let n = pts.count
        let sorted = pts.sorted()

        // Matroska only stores presentation times. Decode order is storage order, so the
        // decode timestamps are the sorted presentation times, shifted back far enough
        // that no frame is decoded after it's shown.
        var shift = 0
        for i in 0..<n { shift = min(shift, pts[i] - sorted[i]) }
        var durations = [Int](repeating: frameDuration, count: n)
        for i in 0..<n - 1 { durations[i] = sorted[i + 1] - sorted[i] }
        var offsets = (0..<n).map { pts[$0] - sorted[$0] - shift }
        if offsets.allSatisfy({ $0 == 0 }) { offsets = [] }

        let prefix = t.strippedHeader
        let track = MovieTrack(media: .video, timescale: timescale, storage: storage(t, frames))
        track.sampleEntry = entry
        track.sizes = frames.sizes.map { $0 + prefix.count }
        track.durations = durations
        track.compositionOffsets = offsets
        track.mediaStart = -shift
        track.presentedLength = track.mediaDuration
        track.emptyEdit = MovieWriter.scale(sorted[0], from: timescale, to: MovieWriter.timescale)
        track.width = Double(width)
        track.height = Double(height)
        track.language = MovieLanguage.code(t)
        if !frames.keyframes.allSatisfy({ $0 }) {
            track.syncSamples = frames.keyframes.indices.filter { frames.keyframes[$0] }.map { $0 + 1 }
        }
        return track
    }

    /// Point at the frames inside the MKV, unless mkvmerge stripped a header off each
    /// one; then the bytes have to be copied with the header put back.
    private func storage(_ t: MatroskaTrack, _ frames: FrameTable) -> MovieTrack.Storage {
        if t.strippedHeader.isEmpty && !copyFrames {
            return .reference(URL(fileURLWithPath: mkv.file.path), offsets: frames.offsets)
        }
        return .copy(mkv.file, prefix: t.strippedHeader, offsets: frames.offsets)
    }

    // MARK: Audio

    private func audioTrack(_ t: MatroskaTrack, origin: Int64) -> MovieTrack? {
        guard let frames = mkv.frames[t.number], t.compression == nil, !t.encrypted else { return nil }
        let prefix = t.strippedHeader
        let file = mkv.file
        func frame(_ i: Int) -> Data { prefix + file.data(frames.offsets[i], frames.sizes[i]) }
        guard let audio = SampleEntries.audio(t, firstFrame: frame(0), frameAt: frame) else { return nil }

        let rate = audio.sampleRate
        if let frameSize = audio.pcmFrameSize {
            let track = MovieTrack(media: .audio, timescale: rate, storage: storage(t, frames))
            track.sampleEntry = audio.entry
            track.constantSampleSize = frameSize
            track.sizes = frames.sizes.map { $0 + prefix.count }
            track.durations = Array(repeating: 1, count: track.sizes.reduce(0) { $0 + $1 / frameSize })
            track.emptyEdit = max(0, Int(((nanoseconds(frames.times[0]) - nanoseconds(origin)) / 1e6).rounded()))
            track.language = MovieLanguage.code(t)
            track.name = t.name
            return track
        }
        var durations = [Int](repeating: 0, count: frames.count)
        var elapsed = 0
        let firstNs = nanoseconds(frames.times[0])
        for i in 0..<frames.count {
            // A gap in the stream (dropped packets in a recording) would slowly push the
            // audio out of sync, so stretch the frame before it to land on time again.
            if i > 0, frames.times[i] != frames.times[i - 1] {
                let expected = Int(((nanoseconds(frames.times[i]) - firstNs) * Double(rate) / 1e9).rounded())
                let late = expected - elapsed
                if late > durations[i - 1] * 2 {
                    durations[i - 1] += late
                    elapsed += late
                }
            }
            durations[i] = audio.frameDurations(i)
            elapsed += durations[i]
        }

        let track = MovieTrack(media: .audio, timescale: rate, storage: storage(t, frames))
        track.sampleEntry = audio.entry
        track.sizes = frames.sizes.map { $0 + prefix.count }
        track.durations = durations
        // Opus starts with a few ms of decoder warm-up that the file says to skip.
        track.mediaStart = audio.priming
        let delayNs = Double(t.codecDelay > 0 ? t.codecDelay : UInt64(audio.priming) * 1_000_000_000 / UInt64(rate))
        track.emptyEdit = max(0, Int(((firstNs - nanoseconds(origin) - (audio.priming > 0 ? delayNs : 0)) / 1e6).rounded()))
        track.language = MovieLanguage.code(t)
        track.name = t.name
        return track
    }

    /// Presentation times in the track's timescale. Constant frame rate video gets
    /// snapped to its real frame grid (24000/1001 and friends), because Matroska
    /// rounds every timestamp to the millisecond.
    private func videoTimestamps(_ t: MatroskaTrack, _ frames: FrameTable, origin: Int64) -> (Int, Int, [Int]) {
        let relative = frames.times.map { nanoseconds($0 - origin) }
        if t.defaultDuration > 0 {
            let fps = 1e9 / Double(t.defaultDuration)
            for (rate, duration) in [(fps.rounded(), 1000), ((fps * 1.001).rounded(), 1001)] where rate > 0 {
                let timescale = Int(rate) * 1000
                let frameNs = 1e9 * Double(duration) / Double(timescale)
                guard abs(frameNs - Double(t.defaultDuration)) < 1000 else { continue }
                var pts: [Int] = []
                pts.reserveCapacity(relative.count)
                var fits = true
                for ns in relative {
                    let k = (ns / frameNs).rounded()
                    if abs(ns - k * frameNs) > frameNs * 0.4 { fits = false; break }
                    pts.append(Int(k) * duration)
                }
                if fits { return (timescale, duration, pts) }
            }
        }
        let timescale = ticksPerSecond <= 1_000_000 && ticksPerSecond == ticksPerSecond.rounded() ? Int(ticksPerSecond) : 90000
        let pts = relative.map { Int(($0 * Double(timescale) / 1e9).rounded()) }
        let frameDuration = t.defaultDuration > 0
            ? max(1, Int((Double(t.defaultDuration) * Double(timescale) / 1e9).rounded()))
            : max(1, timescale / 25)
        return (timescale, frameDuration, pts)
    }

    func codecName(_ t: MatroskaTrack) -> String {
        let names = ["V_MPEG4/ISO/AVC": "H.264", "V_MPEGH/ISO/HEVC": "HEVC", "V_AV1": "AV1", "V_VP9": "VP9",
                     "V_VP8": "VP8", "V_MPEG2": "MPEG-2", "V_MS/VFW/FOURCC": "VfW", "V_THEORA": "Theora",
                     "V_PRORES": "ProRes", "A_DTS": "DTS", "A_TRUEHD": "TrueHD", "A_VORBIS": "Vorbis",
                     "A_AAC": "AAC", "A_AC3": "AC-3", "A_EAC3": "E-AC-3", "A_OPUS": "Opus", "A_FLAC": "FLAC",
                     "A_MPEG/L3": "MP3", "A_MPEG/L2": "MP2", "S_HDMV/PGS": "PGS", "S_VOBSUB": "VobSub"]
        return names[t.codec] ?? names.first { t.codec.hasPrefix($0.key) }?.value ?? t.codec
    }
}

enum MovieLanguage {
    /// Matroska uses ISO 639-2/B codes; QuickTime wants 639-2/T.
    static let bibliographic = ["alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces",
                                "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
                                "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "rum": "ron", "slo": "slk",
                                "tib": "bod", "wel": "cym"]

    static func code(_ t: MatroskaTrack) -> String {
        if !t.languageBCP47.isEmpty, let alpha3 = alpha3(t.languageBCP47) { return alpha3 }
        let lang = t.language.lowercased()
        return bibliographic[lang] ?? (lang.count == 3 ? lang : "und")
    }

    static func alpha3(_ tag: String) -> String? {
        let base = String(tag.split(separator: "-").first ?? "")
        if base.count == 3 { return bibliographic[base] ?? base }
        return Locale.LanguageCode(base).identifier(.alpha3)
    }
}
