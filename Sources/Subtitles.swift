import Foundation
import Compression

/// A subtitle cue in milliseconds from the start of the movie.
struct Cue {
    var start: Int
    var end: Int
    var text: StyledText
}

/// Plain text plus bold/italic/underline runs, measured in characters.
struct StyledText {
    var text = ""
    var runs: [(start: Int, end: Int, face: UInt8)] = []

    static let bold: UInt8 = 1, italic: UInt8 = 2, underline: UInt8 = 4

    /// Reads SRT/WebVTT tags (<i>, <b>, <u>, <font>) and ASS override blocks
    /// ({\i1}, {\b0}, {\p1}...) into style runs, and drops everything else.
    init(markup raw: String) {
        var face: UInt8 = 0
        var drawing = false
        var runStart = 0
        var length = 0
        var out = ""
        let chars = Array(raw.replacingOccurrences(of: "\r", with: ""))

        func setFace(_ new: UInt8) {
            guard new != face else { return }
            if face != 0 && length > runStart { runs.append((runStart, length, face)) }
            face = new
            runStart = length
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "<", let close = chars[i...].firstIndex(of: ">") {
                let tag = String(chars[(i + 1)..<close]).lowercased().trimmingCharacters(in: .whitespaces)
                let closing = tag.hasPrefix("/")
                let name = tag.trimmingCharacters(in: CharacterSet(charactersIn: "/")).prefix { $0.isLetter }
                let bit: UInt8 = name == "i" ? StyledText.italic : name == "b" ? StyledText.bold : name == "u" ? StyledText.underline : 0
                if bit != 0 { setFace(closing ? face & ~bit : face | bit) }
                i = close + 1
                continue
            }
            if c == "{", let close = chars[i...].firstIndex(of: "}") {
                let block = String(chars[(i + 1)..<close])
                for code in block.split(separator: "\\") {
                    switch code {
                    case "i1": setFace(face | StyledText.italic)
                    case "i0": setFace(face & ~StyledText.italic)
                    case "b1": setFace(face | StyledText.bold)
                    case "b0": setFace(face & ~StyledText.bold)
                    case "u1": setFace(face | StyledText.underline)
                    case "u0": setFace(face & ~StyledText.underline)
                    case "r": setFace(0)
                    case let p where p.hasPrefix("p"): drawing = p != "p0"
                    default: break
                    }
                }
                i = close + 1
                continue
            }
            if c == "\\", i + 1 < chars.count, "Nnh".contains(chars[i + 1]) {
                let replacement: Character = chars[i + 1] == "h" ? " " : "\n"
                if !drawing { out.append(replacement); length += 1 }
                i += 2
                continue
            }
            if !drawing {
                out.append(c)
                length += 1
            }
            i += 1
        }
        setFace(0)

        // Trim spaces around each line without breaking the run offsets.
        let trimmed = out.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
        if trimmed.count != out.count { runs = [] }
        text = trimmed
    }

    init() {}

    var isEmpty: Bool { text.isEmpty }

    func appending(_ other: StyledText) -> StyledText {
        guard !isEmpty else { return other }
        var joined = self
        let shift = text.count + 1
        joined.text += "\n" + other.text
        joined.runs += other.runs.map { ($0.start + shift, $0.end + shift, $0.face) }
        return joined
    }
}

enum Subtitles {
    static let textCodecs: Set<String> = ["S_TEXT/UTF8", "S_TEXT/ASCII", "S_TEXT/ASS", "S_TEXT/SSA", "S_ASS", "S_SSA", "S_TEXT/WEBVTT"]

    /// Cues from a Matroska subtitle track, or nil for bitmap formats we can't show.
    static func cues(_ t: MatroskaTrack, _ frames: FrameTable, file: MappedFile, timestampScale: UInt64, origin: Int64) -> [Cue]? {
        guard textCodecs.contains(t.codec), !t.encrypted, t.compression == nil || t.compression == 0 else { return nil }
        let ass = t.codec.contains("ASS") || t.codec.contains("SSA")
        let msPerTick = Double(timestampScale) / 1e6
        var cues: [Cue] = []
        for i in 0..<frames.count {
            var data = t.strippedHeader + file.data(frames.offsets[i], frames.sizes[i])
            if t.compression == 0 { data = inflate(data) ?? Data() }
            var raw = String(decoding: data, as: UTF8.self)
            if ass {
                // ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV, Effect, Text
                let fields = raw.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                raw = fields.count == 9 ? String(fields[8]) : raw
            }
            let text = StyledText(markup: raw)
            guard !text.isEmpty else { continue }
            let start = Int((Double(frames.times[i] - origin) * msPerTick).rounded())
            let duration = frames.durations[i] > 0 ? Int((Double(frames.durations[i]) * msPerTick).rounded()) : 0
            cues.append(Cue(start: max(0, start), end: max(0, start) + duration, text: text))
        }
        // Blocks without a duration last until the next cue, at most five seconds.
        cues.sort { $0.start < $1.start }
        for i in cues.indices where cues[i].end <= cues[i].start {
            let next = i + 1 < cues.count ? cues[i + 1].start : cues[i].start + 5000
            cues[i].end = min(next, cues[i].start + 5000)
        }
        return cues
    }

    /// Matroska's zlib compression is a normal zlib stream; Apple's decoder wants raw deflate.
    static func inflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let src = Array(data.dropFirst(2))
        var dst = [UInt8](repeating: 0, count: max(4096, src.count * 8))
        let n = compression_decode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_ZLIB)
        return n > 0 ? Data(dst[0..<n]) : nil
    }

    /// A tx3g track. Overlapping cues are shown together; gaps get empty samples.
    static func track(_ cues: [Cue], language: String, name: String) -> MovieTrack? {
        guard !cues.isEmpty else { return nil }
        let sorted = cues.sorted { $0.start < $1.start }
        var bounds = Array(Set(sorted.flatMap { [$0.start, $0.end] })).sorted()
        bounds = bounds.filter { $0 >= 0 }

        var samples: [Data] = []
        var durations: [Int] = []
        var cursor = 0
        var first = 0
        for k in 0..<max(0, bounds.count - 1) {
            let a = bounds[k], b = bounds[k + 1]
            while first < sorted.count && sorted[first].end <= a { first += 1 }
            var text = StyledText()
            for cue in sorted[first...] {
                if cue.start >= b { break }
                if cue.start <= a && cue.end >= b { text = text.appending(cue.text) }
            }
            if text.isEmpty { continue }
            if a > cursor {
                samples.append(Data([0, 0]))
                durations.append(a - cursor)
            }
            let sample = encode(text)
            if a == cursor, let last = samples.last, last == sample, !durations.isEmpty {
                durations[durations.count - 1] += b - a
            } else {
                samples.append(sample)
                durations.append(b - a)
            }
            cursor = b
        }
        guard !samples.isEmpty else { return nil }

        let track = MovieTrack(media: .subtitle, timescale: 1000, storage: .inline(samples))
        track.sampleEntry = sampleEntry
        track.sizes = samples.map(\.count)
        track.durations = durations
        track.language = language
        track.name = name
        track.isEnabled = false
        track.alternateGroup = 2
        return track
    }

    static func encode(_ s: StyledText) -> Data {
        var b = Boxes()
        let utf8 = Array(s.text.utf8)
        b.u16(UInt16(clamping: utf8.count))
        b.append(utf8)
        if !s.runs.isEmpty {
            b.box("styl") { b in
                b.u16(UInt16(s.runs.count))
                for run in s.runs {
                    b.u16(UInt16(clamping: run.start))
                    b.u16(UInt16(clamping: run.end))
                    b.u16(1)          // font id
                    b.u8(run.face)
                    b.u8(18)
                    b.u32(0xFFFF_FFFF)
                }
            }
        }
        return Data(b.bytes)
    }

    /// Same defaults ffmpeg writes; the look comes from the user's caption settings anyway.
    static let sampleEntry: [UInt8] = {
        var b = Boxes()
        b.box("tx3g") { b in
            b.zeros(6)
            b.u16(1)
            b.u32(0)                  // display flags
            b.u8(1)                   // centered
            b.u8(0xFF)                // bottom
            b.u32(0)                  // background
            b.zeros(8)                // default text box
            b.u16(0); b.u16(0); b.u16(1); b.u8(0); b.u8(18); b.u32(0xFFFF_FFFF)
            b.box("ftab") { b in
                let font = Array("Sans-Serif".utf8)
                b.u16(1)
                b.u16(1)
                b.u8(UInt8(font.count))
                b.append(font)
            }
        }
        return b.bytes
    }()
}
