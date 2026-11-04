import Foundation

struct MatroskaTrack {
    enum Kind { case video, audio, subtitle, other }

    var number = 0
    var kind = Kind.other
    var codec = ""
    var codecPrivate = Data()
    var name = ""
    var language = "eng"          // the spec's default when the element is missing
    var languageBCP47 = ""
    var isEnabled = true
    var isDefault = true
    var isForced = false
    var defaultDuration: UInt64 = 0   // nanoseconds per frame
    var codecDelay: UInt64 = 0        // nanoseconds

    var pixelWidth = 0, pixelHeight = 0
    var displayWidth = 0, displayHeight = 0, displayUnit = 0
    var matrix = 2, primaries = 2, transfer = 2, colourRange = 0, bitsPerChannel = 0

    var sampleRate = 8000.0
    var outputSampleRate = 0.0
    var channels = 1
    var bitDepth = 0

    /// Bytes mkvmerge removed from the front of every frame ("header stripping").
    var strippedHeader = Data()
    /// zlib, bzip2, lzo or encryption on frames. We only undo zlib, and only for subtitles.
    var compression: Int?
    var encrypted = false
}

/// Where every frame of one track sits in the file, in storage (decode) order.
struct FrameTable {
    var offsets: [Int] = []
    var sizes: [Int] = []
    var times: [Int64] = []       // presentation timestamps, in segment ticks
    var durations: [Int64] = []   // BlockDuration in ticks, 0 when absent
    var keyframes: [Bool] = []

    var count: Int { offsets.count }
}

final class MatroskaFile {
    let file: MappedFile
    private let reader: EBMLReader

    var docType = "matroska"
    var timestampScale: UInt64 = 1_000_000   // nanoseconds per tick
    var duration = 0.0                       // ticks
    var title = ""
    var tracks: [MatroskaTrack] = []
    var frames: [Int: FrameTable] = [:]      // keyed by track number
    /// Chapters of the default edition, start times in nanoseconds.
    var chapters: [(title: String, start: UInt64)] = []

    init(path: String) throws {
        file = try MappedFile(path: path)
        reader = EBMLReader(file: file)
        try parse()
    }

    var durationSeconds: Double { duration * Double(timestampScale) / 1e9 }

    private func parse() throws {
        guard let header = reader.element(at: 0, limit: file.size), header.id == MKV.ebml else {
            throw MediaError("Not a Matroska file")
        }
        reader.children(of: header) { if $0.id == MKV.docType { docType = reader.string($0) } }

        var pos = header.end
        while let el = reader.element(at: pos, limit: file.size) {
            if el.id == MKV.segment {
                parseSegment(el)
                break
            }
            if el.unknownSize { break }
            pos = el.end
        }
        guard !tracks.isEmpty else { throw MediaError("No tracks in this file") }
    }

    private func parseSegment(_ segment: EBMLElement) {
        var pos = segment.start
        while let el = reader.element(at: pos, limit: segment.end) {
            switch el.id {
            case MKV.info: parseInfo(el)
            case MKV.tracks: parseTracks(el)
            case MKV.chapters: parseChapters(el)
            case MKV.cluster:
                pos = parseCluster(el)
                continue
            default: break
            }
            if el.unknownSize { break }
            pos = el.end
        }
        // Garbage in the middle of the file: look for the next cluster and carry on.
        if pos < segment.end, let next = findCluster(after: pos, limit: segment.end) {
            var rest = segment
            rest = EBMLElement(id: rest.id, headerStart: rest.headerStart, start: next, end: rest.end, unknownSize: rest.unknownSize)
            parseSegment(rest)
        }
    }

    private func findCluster(after pos: Int, limit: Int) -> Int? {
        let b = file.bytes
        var i = pos + 1
        while i + 4 <= limit {
            if b[i] == 0x1F, b[i + 1] == 0x43, b[i + 2] == 0xB6, b[i + 3] == 0x75 { return i }
            i += 1
        }
        return nil
    }

    /// Returns where parsing should continue. For unknown-size clusters that's the
    /// first top-level element after the cluster's blocks.
    private func parseCluster(_ cluster: EBMLElement) -> Int {
        var clusterTime: Int64 = 0
        var pos = cluster.start
        file.prefetch(from: pos)
        while let el = reader.element(at: pos, limit: cluster.end) {
            switch el.id {
            case MKV.clusterTimestamp:
                clusterTime = Int64(reader.uint(el))
            case MKV.simpleBlock:
                addBlock(el.start, el.end, clusterTime: clusterTime, keyframe: nil, duration: 0)
            case MKV.blockGroup:
                var block: EBMLElement?
                var duration: Int64 = 0
                var isKey = true
                reader.children(of: el) { c in
                    switch c.id {
                    case MKV.block: block = c
                    case MKV.blockDuration: duration = Int64(reader.uint(c))
                    case MKV.referenceBlock: isKey = false
                    default: break
                    }
                }
                if let block { addBlock(block.start, block.end, clusterTime: clusterTime, keyframe: isKey, duration: duration) }
            default:
                if cluster.unknownSize && MKV.topLevel.contains(el.id) { return pos }
            }
            if el.unknownSize { return el.end }
            pos = el.end
        }
        return cluster.unknownSize ? pos : cluster.end
    }

    private func addBlock(_ start: Int, _ end: Int, clusterTime: Int64, keyframe: Bool?, duration: Int64) {
        let b = file.bytes
        guard let track = reader.vint(at: start, limit: end), let number = track.value else { return }
        var p = start + track.length
        guard p + 3 <= end else { return }
        let relative = Int16(bitPattern: UInt16(b[p]) << 8 | UInt16(b[p + 1]))
        let flags = b[p + 2]
        p += 3
        let time = clusterTime + Int64(relative)
        let isKey = keyframe ?? (flags & 0x80 != 0)

        var sizes: [Int] = []
        let lacing = (flags >> 1) & 3
        if lacing == 0 {
            sizes = [end - p]
        } else {
            guard p < end else { return }
            let count = Int(b[p]) + 1
            p += 1
            switch lacing {
            case 1:  // Xiph: each size is a run of 255s plus a final byte
                for _ in 0..<count - 1 {
                    var size = 0
                    while p < end {
                        let v = Int(b[p])
                        p += 1
                        size += v
                        if v != 255 { break }
                    }
                    sizes.append(size)
                }
            case 3:  // EBML: first size, then signed differences
                guard let first = reader.vint(at: p, limit: end), let firstSize = first.value else { return }
                p += first.length
                sizes.append(Int(firstSize))
                for _ in 0..<max(0, count - 2) {
                    guard let d = reader.vint(at: p, limit: end), let raw = d.value else { return }
                    p += d.length
                    let bias = (Int64(1) << (7 * Int64(d.length) - 1)) - 1
                    sizes.append(sizes[sizes.count - 1] + Int(Int64(raw) - bias))
                }
            default:  // fixed
                let each = (end - p) / count
                sizes = Array(repeating: each, count: count - 1)
            }
            let used = sizes.reduce(0, +)
            guard sizes.allSatisfy({ $0 >= 0 }), used <= end - p else { return }
            sizes.append(end - p - used)
        }

        var table = frames[Int(number), default: FrameTable()]
        frames[Int(number)] = nil  // keep the arrays uniquely referenced while appending
        for size in sizes {
            table.offsets.append(p)
            table.sizes.append(size)
            table.times.append(time)
            table.durations.append(duration)
            table.keyframes.append(isKey)
            p += size
        }
        frames[Int(number)] = table
    }

    private func parseInfo(_ info: EBMLElement) {
        reader.children(of: info) { el in
            switch el.id {
            case MKV.timestampScale: timestampScale = max(1, reader.uint(el))
            case MKV.duration: duration = reader.float(el)
            case MKV.title: title = reader.string(el)
            default: break
            }
        }
    }

    /// Only the top level of the default (or first visible) edition. Nested chapters
    /// and ordered editions that splice other files together are out of scope.
    private func parseChapters(_ list: EBMLElement) {
        var editions: [(isDefault: Bool, chapters: [(String, UInt64)])] = []
        reader.children(of: list) { edition in
            guard edition.id == MKV.editionEntry else { return }
            var hidden = false, isDefault = false
            var found: [(String, UInt64)] = []
            reader.children(of: edition) { el in
                switch el.id {
                case MKV.editionFlagHidden: hidden = reader.uint(el) != 0
                case MKV.editionFlagDefault: isDefault = reader.uint(el) != 0
                case MKV.chapterAtom:
                    var start: UInt64 = 0, title = "", skip = false
                    reader.children(of: el) { c in
                        switch c.id {
                        case MKV.chapterTimeStart: start = reader.uint(c)
                        case MKV.chapterFlagHidden: skip = skip || reader.uint(c) != 0
                        case MKV.chapterFlagEnabled: skip = skip || reader.uint(c) == 0
                        case MKV.chapterDisplay where title.isEmpty:
                            reader.children(of: c) { if $0.id == MKV.chapString { title = reader.string($0) } }
                        default: break
                        }
                    }
                    if !skip { found.append((title, start)) }
                default: break
                }
            }
            if !hidden && !found.isEmpty { editions.append((isDefault, found)) }
        }
        let edition = editions.first { $0.isDefault } ?? editions.first
        chapters = (edition?.chapters ?? []).sorted { $0.1 < $1.1 }.map { (title: $0.0, start: $0.1) }
    }

    private func parseTracks(_ list: EBMLElement) {
        reader.children(of: list) { entry in
            guard entry.id == MKV.trackEntry else { return }
            var t = MatroskaTrack()
            reader.children(of: entry) { el in
                switch el.id {
                case MKV.trackNumber: t.number = Int(reader.uint(el))
                case MKV.trackType:
                    switch reader.uint(el) {
                    case 1: t.kind = .video
                    case 2: t.kind = .audio
                    case 17: t.kind = .subtitle
                    default: t.kind = .other
                    }
                case MKV.codecID: t.codec = reader.string(el)
                case MKV.codecPrivate: t.codecPrivate = reader.data(el)
                case MKV.name: t.name = reader.string(el)
                case MKV.language: t.language = reader.string(el)
                case MKV.languageBCP47: t.languageBCP47 = reader.string(el)
                case MKV.flagEnabled: t.isEnabled = reader.uint(el) != 0
                case MKV.flagDefault: t.isDefault = reader.uint(el) != 0
                case MKV.flagForced: t.isForced = reader.uint(el) != 0
                case MKV.defaultDuration: t.defaultDuration = reader.uint(el)
                case MKV.codecDelay: t.codecDelay = reader.uint(el)
                case MKV.video: parseVideo(el, into: &t)
                case MKV.audio: parseAudio(el, into: &t)
                case MKV.contentEncodings: parseEncodings(el, into: &t)
                default: break
                }
            }
            if t.number > 0 { tracks.append(t) }
        }
    }

    private func parseVideo(_ video: EBMLElement, into t: inout MatroskaTrack) {
        reader.children(of: video) { el in
            switch el.id {
            case MKV.pixelWidth: t.pixelWidth = Int(reader.uint(el))
            case MKV.pixelHeight: t.pixelHeight = Int(reader.uint(el))
            case MKV.displayWidth: t.displayWidth = Int(reader.uint(el))
            case MKV.displayHeight: t.displayHeight = Int(reader.uint(el))
            case MKV.displayUnit: t.displayUnit = Int(reader.uint(el))
            case MKV.colour:
                reader.children(of: el) { c in
                    switch c.id {
                    case MKV.matrixCoefficients: t.matrix = Int(reader.uint(c))
                    case MKV.primaries: t.primaries = Int(reader.uint(c))
                    case MKV.transferCharacteristics: t.transfer = Int(reader.uint(c))
                    case MKV.range: t.colourRange = Int(reader.uint(c))
                    case MKV.bitsPerChannel: t.bitsPerChannel = Int(reader.uint(c))
                    default: break
                    }
                }
            default: break
            }
        }
    }

    private func parseAudio(_ audio: EBMLElement, into t: inout MatroskaTrack) {
        reader.children(of: audio) { el in
            switch el.id {
            case MKV.samplingFrequency: t.sampleRate = reader.float(el)
            case MKV.outputSamplingFrequency: t.outputSampleRate = reader.float(el)
            case MKV.channels: t.channels = Int(reader.uint(el))
            case MKV.bitDepth: t.bitDepth = Int(reader.uint(el))
            default: break
            }
        }
    }

    private func parseEncodings(_ list: EBMLElement, into t: inout MatroskaTrack) {
        reader.children(of: list) { encoding in
            guard encoding.id == MKV.contentEncoding else { return }
            var scope: UInt64 = 1
            var algo: Int?
            var settings = Data()
            reader.children(of: encoding) { el in
                switch el.id {
                case MKV.contentEncodingScope: scope = reader.uint(el)
                case MKV.contentEncryption: t.encrypted = true
                case MKV.contentCompression:
                    algo = 0  // zlib unless the file says otherwise
                    reader.children(of: el) { c in
                        if c.id == MKV.contentCompAlgo { algo = Int(reader.uint(c)) }
                        if c.id == MKV.contentCompSettings { settings = reader.data(c) }
                    }
                default: break
                }
            }
            guard scope & 1 != 0, let algo else { return }  // only frame-level encodings matter
            if algo == 3 { t.strippedHeader = settings } else { t.compression = algo }
        }
    }
}
