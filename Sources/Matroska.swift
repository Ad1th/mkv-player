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

final class MatroskaFile {
    let file: MappedFile
    private let reader: EBMLReader

    var docType = "matroska"
    var timestampScale: UInt64 = 1_000_000   // nanoseconds per tick
    var duration = 0.0                       // ticks
    var title = ""
    var tracks: [MatroskaTrack] = []

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
            default: break
            }
            if el.unknownSize { break }
            pos = el.end
        }
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
