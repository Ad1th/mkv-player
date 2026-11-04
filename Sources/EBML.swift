import Foundation

struct MediaError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A read-only memory map of a file. Pages are only read from disk when
/// something touches them, so indexing a 20 GB file doesn't read 20 GB.
final class MappedFile {
    let bytes: UnsafePointer<UInt8>
    let size: Int
    let path: String
    private let fd: Int32
    private var prefetchedEnd = 0

    init(path: String) throws {
        self.path = path
        fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw MediaError("Couldn't open the file") }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else {
            close(fd)
            throw MediaError("The file is empty")
        }
        size = Int(info.st_size)
        guard let map = mmap(nil, size, PROT_READ, MAP_PRIVATE, fd, 0), map != MAP_FAILED else {
            close(fd)
            throw MediaError("Couldn't map the file")
        }
        bytes = UnsafePointer(map.assumingMemoryBound(to: UInt8.self))
    }

    deinit {
        munmap(UnsafeMutableRawPointer(mutating: bytes), size)
        close(fd)
    }

    /// Asks the kernel to read ahead of the parser. Faulting 16 KB pages one by one
    /// made a cold 250 MB episode take a second to index; this gets it to ~0.2 s
    /// without pulling a whole 20 GB file into memory.
    func prefetch(from pos: Int) {
        let window = 64 << 20
        guard pos + window / 2 > prefetchedEnd, prefetchedEnd < size else { return }
        let page = Int(getpagesize())
        let start = max(prefetchedEnd, pos) / page * page
        let length = min(window, size - start)
        madvise(UnsafeMutableRawPointer(mutating: bytes + start), length, MADV_WILLNEED)
        prefetchedEnd = start + length
    }

    func data(_ start: Int, _ count: Int) -> Data {
        guard start >= 0, count > 0, start + count <= size else { return Data() }
        return Data(bytes: bytes + start, count: count)
    }

    func uint(_ start: Int, _ count: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<min(count, 8) where start + i < size { v = v << 8 | UInt64(bytes[start + i]) }
        return v
    }
}

/// One EBML element. `start..<end` is its payload, clamped to the parent so a
/// truncated download still parses as far as it goes.
struct EBMLElement {
    let id: UInt32
    let headerStart: Int
    let start: Int
    let end: Int
    let unknownSize: Bool
}

struct EBMLReader {
    let file: MappedFile

    /// Variable-length integer as used for element sizes and block track numbers.
    /// Returns the value (nil when every value bit is set, meaning "unknown") and its length.
    func vint(at pos: Int, limit: Int) -> (value: UInt64?, length: Int)? {
        guard pos < limit else { return nil }
        let first = file.bytes[pos]
        guard first != 0 else { return nil }
        let length = first.leadingZeroBitCount + 1
        guard pos + length <= limit else { return nil }
        var value = UInt64(first) & (0xFF >> UInt64(length))
        var allOnes = value == (0xFF >> UInt64(length))
        for i in 1..<length {
            let b = file.bytes[pos + i]
            value = value << 8 | UInt64(b)
            allOnes = allOnes && b == 0xFF
        }
        return (allOnes ? nil : value, length)
    }

    func element(at pos: Int, limit: Int) -> EBMLElement? {
        guard pos < limit else { return nil }
        let first = file.bytes[pos]
        guard first >= 0x10 else { return nil }  // IDs are 1-4 bytes long
        let idLength = first.leadingZeroBitCount + 1
        guard pos + idLength < limit, let size = vint(at: pos + idLength, limit: limit) else { return nil }
        let id = UInt32(file.uint(pos, idLength))
        let start = pos + idLength + size.length
        guard start <= limit else { return nil }
        if let value = size.value {
            let end = value > UInt64(limit - start) ? limit : start + Int(value)
            return EBMLElement(id: id, headerStart: pos, start: start, end: end, unknownSize: false)
        }
        return EBMLElement(id: id, headerStart: pos, start: start, end: limit, unknownSize: true)
    }

    /// Calls `body` for each child of `parent`. Stops early if the data turns into garbage.
    func children(of parent: EBMLElement, _ body: (EBMLElement) -> Void) {
        var pos = parent.start
        while let child = element(at: pos, limit: parent.end) {
            body(child)
            if child.unknownSize { return }
            pos = child.end
        }
    }

    func uint(_ e: EBMLElement) -> UInt64 { file.uint(e.start, e.end - e.start) }

    func float(_ e: EBMLElement) -> Double {
        let raw = file.uint(e.start, e.end - e.start)
        switch e.end - e.start {
        case 4: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw)))
        case 8: return Double(bitPattern: raw)
        default: return 0
        }
    }

    func string(_ e: EBMLElement) -> String {
        var bytes = Array(UnsafeBufferPointer(start: file.bytes + e.start, count: e.end - e.start))
        if let nul = bytes.firstIndex(of: 0) { bytes.removeSubrange(nul...) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func data(_ e: EBMLElement) -> Data { file.data(e.start, e.end - e.start) }
}

/// Element IDs from the Matroska spec, only the ones we read.
enum MKV {
    static let ebml: UInt32 = 0x1A45DFA3
    static let docType: UInt32 = 0x4282
    static let segment: UInt32 = 0x18538067

    static let seekHead: UInt32 = 0x114D9B74
    static let info: UInt32 = 0x1549A966
    static let tracks: UInt32 = 0x1654AE6B
    static let cluster: UInt32 = 0x1F43B675
    static let cues: UInt32 = 0x1C53BB6B
    static let chapters: UInt32 = 0x1043A770
    static let tags: UInt32 = 0x1254C367
    static let attachments: UInt32 = 0x1941A469

    static let timestampScale: UInt32 = 0x2AD7B1
    static let duration: UInt32 = 0x4489
    static let title: UInt32 = 0x7BA9

    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let flagEnabled: UInt32 = 0xB9
    static let flagDefault: UInt32 = 0x88
    static let flagForced: UInt32 = 0x55AA
    static let defaultDuration: UInt32 = 0x23E383
    static let name: UInt32 = 0x536E
    static let language: UInt32 = 0x22B59C
    static let languageBCP47: UInt32 = 0x22B59D
    static let codecID: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let codecDelay: UInt32 = 0x56AA
    static let video: UInt32 = 0xE0
    static let pixelWidth: UInt32 = 0xB0
    static let pixelHeight: UInt32 = 0xBA
    static let displayWidth: UInt32 = 0x54B0
    static let displayHeight: UInt32 = 0x54BA
    static let displayUnit: UInt32 = 0x54B2
    static let colour: UInt32 = 0x55B0
    static let matrixCoefficients: UInt32 = 0x55B1
    static let bitsPerChannel: UInt32 = 0x55B2
    static let range: UInt32 = 0x55B9
    static let transferCharacteristics: UInt32 = 0x55BA
    static let primaries: UInt32 = 0x55BB
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let outputSamplingFrequency: UInt32 = 0x78B5
    static let channels: UInt32 = 0x9F
    static let bitDepth: UInt32 = 0x6264
    static let contentEncodings: UInt32 = 0x6D80
    static let contentEncoding: UInt32 = 0x6240
    static let contentEncodingScope: UInt32 = 0x5032
    static let contentCompression: UInt32 = 0x5034
    static let contentCompAlgo: UInt32 = 0x4254
    static let contentCompSettings: UInt32 = 0x4255
    static let contentEncryption: UInt32 = 0x5035

    static let clusterTimestamp: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let blockDuration: UInt32 = 0x9B
    static let referenceBlock: UInt32 = 0xFB

    static let editionEntry: UInt32 = 0x45B9
    static let editionFlagHidden: UInt32 = 0x45BD
    static let editionFlagDefault: UInt32 = 0x45DB
    static let chapterAtom: UInt32 = 0xB6
    static let chapterTimeStart: UInt32 = 0x91
    static let chapterFlagHidden: UInt32 = 0x98
    static let chapterFlagEnabled: UInt32 = 0x4598
    static let chapterDisplay: UInt32 = 0x80
    static let chapString: UInt32 = 0x85

    /// Level 1 elements. Seeing one inside an unknown-size cluster means the cluster ended.
    static let topLevel: Set<UInt32> = [seekHead, info, tracks, cluster, cues, chapters, tags, attachments, ebml]
}
