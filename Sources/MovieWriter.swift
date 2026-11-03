import Foundation

/// Big-endian byte builder for QuickTime boxes.
struct Boxes {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes += [UInt8(v >> 8), UInt8(v & 0xFF)] }
    mutating func u24(_ v: UInt32) { bytes += [UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    mutating func u32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
    mutating func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(v & 0xFFFF_FFFF)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func fourcc(_ s: String) { bytes += Array((s + "    ").utf8.prefix(4)) }
    mutating func append<S: Sequence>(_ s: S) where S.Element == UInt8 { bytes += s }
    mutating func zeros(_ n: Int) { bytes += [UInt8](repeating: 0, count: n) }

    /// The unity matrix used by mvhd and tkhd.
    mutating func matrix() {
        for v: UInt32 in [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x4000_0000] { u32(v) }
    }

    mutating func box(_ type: String, _ body: (inout Boxes) -> Void) {
        let start = bytes.count
        u32(0)
        fourcc(type)
        body(&self)
        let size = UInt32(bytes.count - start)
        bytes[start] = UInt8(size >> 24)
        bytes[start + 1] = UInt8(size >> 16 & 0xFF)
        bytes[start + 2] = UInt8(size >> 8 & 0xFF)
        bytes[start + 3] = UInt8(size & 0xFF)
    }

    mutating func fullBox(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ body: (inout Boxes) -> Void) {
        box(type) { b in
            b.u8(version)
            b.u24(flags)
            body(&b)
        }
    }
}

/// One output track, already converted to QuickTime's model: per-sample sizes and
/// durations in the track's own timescale, plus where the bytes come from.
final class MovieTrack {
    enum Media { case video, audio, subtitle }

    enum Storage {
        /// Samples are written into this movie's mdat, copied out of `file`
        /// with `prefix` put back in front (for header-stripped tracks).
        case copy(MappedFile, prefix: Data, offsets: [Int])
        /// Small samples built in memory, like subtitle text.
        case inline([Data])
    }

    let media: Media
    var timescale: Int
    var sampleEntry: [UInt8] = []
    var language = "und"
    var name = ""
    var isEnabled = true
    var alternateGroup: Int16 = 0
    var width = 0.0
    var height = 0.0

    var sizes: [Int] = []
    var durations: [Int] = []
    var compositionOffsets: [Int] = []   // empty when nothing is reordered
    var syncSamples: [Int]?              // 1-based; nil means every sample is a sync sample
    var storage: Storage

    /// Movie-timescale gap before the track starts.
    var emptyEdit = 0
    /// Media-timescale amount skipped at the start (B-frame delay, codec priming).
    var mediaStart = 0
    /// How much media time to present. Defaults to everything after `mediaStart`.
    var presentedLength: Int?

    init(media: Media, timescale: Int, storage: Storage) {
        self.media = media
        self.timescale = timescale
        self.storage = storage
    }

    var mediaDuration: Int { durations.reduce(0, +) }
}

enum MovieWriter {
    static let timescale = 1000

    static func write(_ tracks: [MovieTrack], to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: url) else { throw MediaError("Couldn't write the movie") }
        defer { try? out.close() }

        var head = Boxes()
        head.box("ftyp") { b in
            b.fourcc("qt  ")
            b.u32(0x200)
            b.fourcc("qt  ")
        }
        let mdatStart = head.bytes.count
        head.u32(1)
        head.fourcc("mdat")
        head.u64(0)
        var position = head.bytes.count
        var pending = Data(head.bytes)

        // Copy sample bytes into the mdat, remembering where each one landed.
        var chunkOffsets: [[Int]] = []
        for track in tracks {
            var offsets: [Int] = []
            offsets.reserveCapacity(track.sizes.count)
            switch track.storage {
            case .inline(let samples):
                for s in samples {
                    offsets.append(position)
                    pending.append(s)
                    position += s.count
                }
            case .copy(let file, let prefix, let sources):
                for (i, src) in sources.enumerated() {
                    offsets.append(position)
                    pending.append(prefix)
                    pending.append(UnsafeBufferPointer(start: file.bytes + src, count: track.sizes[i] - prefix.count))
                    position += track.sizes[i]
                    if pending.count > 8 << 20 {
                        try out.write(contentsOf: pending)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
            }
            chunkOffsets.append(offsets)
        }
        try out.write(contentsOf: pending)

        let mdatSize = UInt64(position - mdatStart)
        try out.seek(toOffset: UInt64(mdatStart + 8))
        var size = Boxes()
        size.u64(mdatSize)
        try out.write(contentsOf: Data(size.bytes))
        try out.seekToEnd()

        try out.write(contentsOf: Data(movieHeader(tracks, chunkOffsets: chunkOffsets)))
    }

    static func presentationDuration(_ t: MovieTrack) -> Int {
        t.emptyEdit + scale(t.presentedLength ?? (t.mediaDuration - t.mediaStart), from: t.timescale, to: timescale)
    }

    static func scale(_ v: Int, from: Int, to: Int) -> Int {
        Int((Double(v) * Double(to) / Double(from)).rounded())
    }

    private static func movieHeader(_ tracks: [MovieTrack], chunkOffsets: [[Int]]) -> [UInt8] {
        var b = Boxes()
        let duration = tracks.map(presentationDuration).max() ?? 0
        b.box("moov") { b in
            b.fullBox("mvhd") { b in
                b.u32(0); b.u32(0)
                b.u32(UInt32(timescale))
                b.u32(UInt32(clamping: duration))
                b.u32(0x10000)   // rate 1.0
                b.u16(0x100)     // volume 1.0
                b.zeros(10)
                b.matrix()
                b.zeros(24)
                b.u32(UInt32(tracks.count + 1))
            }
            for (i, t) in tracks.enumerated() {
                trak(&b, t, id: i + 1, chunkOffsets: chunkOffsets[i])
            }
        }
        return b.bytes
    }

    private static func trak(_ b: inout Boxes, _ t: MovieTrack, id: Int, chunkOffsets: [Int]) {
        let presented = presentationDuration(t)
        b.box("trak") { b in
            b.fullBox("tkhd", flags: t.isEnabled ? 0x7 : 0x6) { b in
                b.u32(0); b.u32(0)
                b.u32(UInt32(id))
                b.u32(0)
                b.u32(UInt32(clamping: presented))
                b.zeros(8)
                b.i16(0)                       // layer
                b.i16(t.alternateGroup)
                b.u16(t.media == .audio ? 0x100 : 0)
                b.u16(0)
                b.matrix()
                b.u32(UInt32(t.width * 65536))
                b.u32(UInt32(t.height * 65536))
            }
            b.box("edts") { b in
                b.fullBox("elst") { b in
                    b.u32(t.emptyEdit > 0 ? 2 : 1)
                    if t.emptyEdit > 0 {
                        b.u32(UInt32(clamping: t.emptyEdit))
                        b.i32(-1)
                        b.u32(0x10000)
                    }
                    b.u32(UInt32(clamping: presented - t.emptyEdit))
                    b.i32(Int32(clamping: t.mediaStart))
                    b.u32(0x10000)
                }
            }
            b.box("mdia") { b in
                let long = t.mediaDuration > Int(UInt32.max)
                b.fullBox("mdhd", version: long ? 1 : 0) { b in
                    if long { b.u64(0); b.u64(0) } else { b.u32(0); b.u32(0) }
                    b.u32(UInt32(t.timescale))
                    if long { b.u64(UInt64(t.mediaDuration)) } else { b.u32(UInt32(t.mediaDuration)) }
                    b.u16(packedLanguage(t.language))
                    b.u16(0)
                }
                let (subtype, label) = switch t.media {
                case .video: ("vide", "VideoHandler")
                case .audio: ("soun", "SoundHandler")
                case .subtitle: ("sbtl", "SubtitleHandler")
                }
                b.fullBox("hdlr") { b in
                    b.fourcc("mhlr")
                    b.fourcc(subtype)
                    b.zeros(12)
                    b.u8(UInt8(label.utf8.count))
                    b.append(label.utf8)
                }
                b.box("minf") { b in
                    switch t.media {
                    case .video: b.fullBox("vmhd", flags: 1) { $0.zeros(8) }
                    case .audio: b.fullBox("smhd") { $0.zeros(4) }
                    case .subtitle: b.fullBox("nmhd") { _ in }
                    }
                    b.box("dinf") { b in
                        b.fullBox("dref") { b in
                            b.u32(1)
                            b.fullBox("url ", flags: 1) { _ in }
                        }
                    }
                    b.box("stbl") { b in sampleTable(&b, t, chunkOffsets: chunkOffsets) }
                }
            }
        }
    }

    private static func sampleTable(_ b: inout Boxes, _ t: MovieTrack, chunkOffsets: [Int]) {
        b.fullBox("stsd") { b in
            b.u32(1)
            b.append(t.sampleEntry)
        }
        b.fullBox("stts") { b in
            let runs = runLengths(t.durations)
            b.u32(UInt32(runs.count))
            for r in runs { b.u32(UInt32(r.count)); b.u32(UInt32(clamping: r.value)) }
        }
        if !t.compositionOffsets.isEmpty {
            b.fullBox("ctts") { b in
                let runs = runLengths(t.compositionOffsets)
                b.u32(UInt32(runs.count))
                for r in runs { b.u32(UInt32(r.count)); b.u32(UInt32(clamping: r.value)) }
            }
        }
        if let sync = t.syncSamples {
            b.fullBox("stss") { b in
                b.u32(UInt32(sync.count))
                for s in sync { b.u32(UInt32(s)) }
            }
        }
        b.fullBox("stsc") { b in
            b.u32(1)
            b.u32(1); b.u32(1); b.u32(1)   // one sample per chunk
        }
        b.fullBox("stsz") { b in
            b.u32(0)
            b.u32(UInt32(t.sizes.count))
            for s in t.sizes { b.u32(UInt32(s)) }
        }
        if (chunkOffsets.last ?? 0) > Int(UInt32.max) {
            b.fullBox("co64") { b in
                b.u32(UInt32(chunkOffsets.count))
                for o in chunkOffsets { b.u64(UInt64(o)) }
            }
        } else {
            b.fullBox("stco") { b in
                b.u32(UInt32(chunkOffsets.count))
                for o in chunkOffsets { b.u32(UInt32(o)) }
            }
        }
    }

    static func runLengths(_ values: [Int]) -> [(count: Int, value: Int)] {
        var runs: [(count: Int, value: Int)] = []
        for v in values {
            if let last = runs.last, last.value == v {
                runs[runs.count - 1].count += 1
            } else {
                runs.append((1, v))
            }
        }
        return runs
    }

    /// ISO 639-2/T code packed into 15 bits, as mdhd wants it.
    static func packedLanguage(_ code: String) -> UInt16 {
        let letters = Array(code.lowercased().utf8)
        guard letters.count == 3, letters.allSatisfy({ $0 >= 0x61 && $0 <= 0x7A }) else { return 0x55C4 }  // "und"
        return letters.reduce(0) { $0 << 5 | UInt16($1 - 0x60) }
    }
}
