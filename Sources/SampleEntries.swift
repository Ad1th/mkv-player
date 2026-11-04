import Foundation
import VideoToolbox

/// Builds stsd entries for the codecs AVFoundation can decode.
enum SampleEntries {
    static func video(_ t: MatroskaTrack, width: Int, height: Int, firstFrame: Data) -> [UInt8]? {
        let cp = t.codecPrivate
        switch t.codec {
        case "V_MPEG4/ISO/AVC" where cp.count > 6:
            return visual("avc1", t, width, height) { $0.box("avcC") { $0.append(cp) } }
        case "V_MPEGH/ISO/HEVC" where cp.count > 22:
            return visual("hvc1", t, width, height) { $0.box("hvcC") { $0.append(cp) } }
        case "V_AV1" where cp.count >= 4 && VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1):
            return visual("av01", t, width, height) { $0.box("av1C") { $0.append(cp) } }
        case "V_VP9":
            guard let vp9 = VP9Header(firstFrame) else { return nil }
            return visual("vp09", t, width, height) { b in
                b.fullBox("vpcC", version: 1) { b in
                    let pixels = t.pixelWidth * t.pixelHeight
                    b.u8(UInt8(vp9.profile))
                    b.u8(pixels <= 921_600 ? 31 : pixels <= 2_228_224 ? 41 : pixels <= 8_912_896 ? 51 : 61)
                    b.u8(UInt8(vp9.bitDepth << 4 | vp9.chroma << 1 | vp9.fullRange))
                    let colour = vp9.colour
                    b.u8(UInt8(t.primaries != 2 ? t.primaries : colour.primaries))
                    b.u8(UInt8(t.transfer != 2 ? t.transfer : colour.transfer))
                    b.u8(UInt8(t.matrix != 2 ? t.matrix : colour.matrix))
                    b.u16(0)
                }
            }
        default:
            return nil
        }
    }

    struct Audio {
        var entry: [UInt8]
        var sampleRate: Int
        /// Audio frames in each Matroska frame.
        var frameDurations: (Int) -> Int
        /// Decoder delay to trim from the start, in samples.
        var priming = 0
        /// Set for uncompressed audio: bytes in one audio frame.
        var pcmFrameSize: Int?
    }

    static func audio(_ t: MatroskaTrack, firstFrame: Data, frameAt: @escaping (Int) -> Data) -> Audio? {
        let rate = Int(t.sampleRate.rounded())
        let cp = t.codecPrivate
        switch t.codec {
        case let c where c.hasPrefix("A_AAC"):
            guard let asc = audioSpecificConfig(t), let info = AACConfig(asc) else { return nil }
            let entry = sound("mp4a", channels: info.channels > 0 ? info.channels : t.channels, rate: info.sampleRate) {
                $0.fullBox("esds") { $0.append(esDescriptor(objectType: 0x40, streamType: 0x15, config: asc)) }
            }
            return Audio(entry: entry, sampleRate: info.sampleRate, frameDurations: { _ in 1024 })

        case "A_AC3":
            guard let ac3 = AC3Header(firstFrame) else { return nil }
            let entry = sound("ac-3", channels: ac3.channels, rate: ac3.sampleRate) {
                $0.box("dac3") { b in
                    let bits = UInt32(ac3.fscod) << 22 | UInt32(ac3.bsid) << 17 | UInt32(ac3.bsmod) << 14
                        | UInt32(ac3.acmod) << 11 | UInt32(ac3.lfeon) << 10 | UInt32(ac3.bitRateCode) << 5
                    b.u24(bits)
                }
            }
            return Audio(entry: entry, sampleRate: ac3.sampleRate, frameDurations: { _ in 1536 })

        case "A_EAC3":
            guard let e = EAC3Header(firstFrame) else { return nil }
            let entry = sound("ec-3", channels: e.channels, rate: e.sampleRate) {
                $0.box("dec3") { b in
                    b.u16(UInt16(min(e.kbps, 8191)) << 3)   // data rate, one independent substream
                    let dependent = UInt32(min(e.dependentSubstreams, 1))
                    b.u24(UInt32(e.fscod) << 22 | UInt32(e.bsid) << 17 | UInt32(e.acmod) << 9
                          | UInt32(e.lfeon) << 8 | dependent << 1)
                    if dependent > 0 { b.u8(0x02) }   // chan_loc: the usual 7.1 back pair (Lrs/Rrs)
                }
            }
            return Audio(entry: entry, sampleRate: e.sampleRate) { EAC3Header.samples(in: frameAt($0)) ?? 1536 }

        case "A_MPEG/L3", "A_MPEG/L2":
            guard firstFrame.count >= 4 else { return nil }
            let version = (firstFrame[firstFrame.startIndex + 1] >> 3) & 3   // 3 = MPEG-1
            let perFrame = t.codec == "A_MPEG/L2" || version == 3 ? 1152 : 576
            let entry = sound(t.codec == "A_MPEG/L3" ? ".mp3" : ".mp2", channels: t.channels, rate: rate) { _ in }
            return Audio(entry: entry, sampleRate: rate, frameDurations: { _ in perFrame })

        case "A_FLAC":
            guard let info = FLACInfo(t.codecPrivate) else { return nil }
            let entry = sound("fLaC", channels: info.channels, rate: info.sampleRate) {
                $0.fullBox("dfLa") { b in
                    b.u8(0x80)   // last metadata block, STREAMINFO
                    b.u24(UInt32(info.streamInfo.count))
                    b.append(info.streamInfo)
                }
            }
            let fixed = info.minBlock == info.maxBlock ? info.minBlock : nil
            return Audio(entry: entry, sampleRate: info.sampleRate) { i in
                fixed ?? FLACInfo.blockSize(frameAt(i)) ?? info.maxBlock
            }

        case "A_OPUS":
            guard let head = OpusHead(t.codecPrivate) else { return nil }
            let entry = sound("Opus", channels: head.channels, rate: 48000) {
                $0.box("dOps") { b in
                    b.u8(0)
                    b.u8(UInt8(head.channels))
                    b.u16(UInt16(head.preSkip))
                    b.u32(UInt32(head.inputRate))
                    b.i16(Int16(head.gain))
                    b.u8(UInt8(head.family))
                    if head.family != 0 { b.append(head.mapping) }
                }
            }
            var audio = Audio(entry: entry, sampleRate: 48000) { OpusHead.samples(in: frameAt($0)) }
            audio.priming = head.preSkip
            return audio

        case "A_ALAC":
            // CodecPrivate is the 24-byte ALACSpecificConfig, sometimes with a box header in front.
            let cookie = cp.count > 24 ? cp.suffix(24) : cp
            guard cookie.count == 24 else { return nil }
            let c = Array(cookie)
            let frameLength = Int(c[0]) << 24 | Int(c[1]) << 16 | Int(c[2]) << 8 | Int(c[3])
            let alacRate = Int(c[20]) << 24 | Int(c[21]) << 16 | Int(c[22]) << 8 | Int(c[23])
            let entry = sound("alac", channels: Int(c[9]), rate: alacRate) {
                $0.fullBox("alac") { $0.append(cookie) }
            }
            return Audio(entry: entry, sampleRate: alacRate, frameDurations: { _ in frameLength })

        case "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE":
            // ISO 23003-5 PCM, the only uncompressed entry AVFoundation reads in an ISO file.
            // 8-bit Matroska PCM is unsigned, which this can't describe.
            let bits = t.bitDepth > 0 ? t.bitDepth : 16
            guard [16, 24, 32, 64].contains(bits) else { return nil }
            let float = t.codec == "A_PCM/FLOAT/IEEE"
            let entry = sound(float ? "fpcm" : "ipcm", channels: t.channels, rate: rate, bits: bits) { b in
                if t.channels > 2 {
                    // L R C LFE Ls Rs, then whatever is left in the usual order.
                    let positions: [UInt8] = [0, 1, 2, 3, 8, 9, 10, 11]
                    b.fullBox("chnl") { b in
                        b.u8(1)
                        b.u8(0)
                        for i in 0..<t.channels { b.u8(i < positions.count ? positions[i] : 126) }
                    }
                }
                b.fullBox("pcmC") { b in
                    b.u8(t.codec == "A_PCM/INT/BIG" ? 0 : 1)
                    b.u8(UInt8(bits))
                }
            }
            var audio = Audio(entry: entry, sampleRate: rate) { _ in 1 }
            audio.pcmFrameSize = bits / 8 * max(1, t.channels)
            return audio

        default:
            return nil
        }
    }

    static func sound(_ fourcc: String, channels: Int, rate: Int, bits: Int = 16, _ config: (inout Boxes) -> Void) -> [UInt8] {
        var b = Boxes()
        b.box(fourcc) { b in
            b.zeros(6)
            b.u16(1)
            b.zeros(8)             // version, revision, vendor
            b.u16(UInt16(clamping: channels))
            b.u16(UInt16(bits))
            b.zeros(4)             // compression id, packet size
            b.u32(rate < 65536 ? UInt32(rate) << 16 : 0)
            config(&b)
        }
        return b.bytes
    }

    /// MPEG-4 ES_Descriptor wrapping a DecoderConfigDescriptor.
    static func esDescriptor(objectType: UInt8, streamType: UInt8, config: Data) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            var out = [tag]
            var length = body.count
            var lengthBytes = [UInt8(length & 0x7F)]
            length >>= 7
            while length > 0 {
                lengthBytes.insert(UInt8(length & 0x7F) | 0x80, at: 0)
                length >>= 7
            }
            out += lengthBytes
            return out + body
        }
        var decoderConfig = Boxes()
        decoderConfig.u8(objectType)
        decoderConfig.u8(streamType)
        decoderConfig.u24(0)
        decoderConfig.u32(0)
        decoderConfig.u32(0)
        let dc = decoderConfig.bytes + (config.isEmpty ? [] : descriptor(0x05, Array(config)))
        return descriptor(0x03, [0, 0, 0] + descriptor(0x04, dc) + descriptor(0x06, [0x02]))
    }

    static let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// Old files use codec IDs like A_AAC/MPEG4/LC/SBR and leave CodecPrivate empty.
    static func audioSpecificConfig(_ t: MatroskaTrack) -> Data? {
        if t.codecPrivate.count >= 2 { return t.codecPrivate }
        let profile: UInt16 = t.codec.contains("MAIN") ? 1 : t.codec.contains("SSR") ? 3 : t.codec.contains("LTP") ? 4 : 2
        guard let index = aacRates.firstIndex(of: Int(t.sampleRate.rounded())) else { return nil }
        let asc = profile << 11 | UInt16(index) << 7 | UInt16(min(t.channels, 7)) << 3
        return Data([UInt8(asc >> 8), UInt8(asc & 0xFF)])
    }

    static func visual(_ fourcc: String, _ t: MatroskaTrack, _ width: Int, _ height: Int,
                       _ config: (inout Boxes) -> Void) -> [UInt8] {
        var b = Boxes()
        b.box(fourcc) { b in
            b.zeros(6)
            b.u16(1)               // data reference index
            b.zeros(16)            // version, revision, vendor, temporal and spatial quality
            b.u16(UInt16(clamping: t.pixelWidth))
            b.u16(UInt16(clamping: t.pixelHeight))
            b.u32(0x480000)        // 72 dpi
            b.u32(0x480000)
            b.u32(0)
            b.u16(1)               // frames per sample
            b.zeros(32)            // compressor name
            b.u16(0x18)
            b.i16(-1)
            config(&b)
            if width != t.pixelWidth && t.pixelWidth > 0 && t.pixelHeight > 0 {
                // Anamorphic video: tell the player how wide a pixel is.
                var h = width * t.pixelHeight, v = height * t.pixelWidth
                let g = gcd(h, v)
                h /= g; v /= g
                b.box("pasp") { b in b.u32(UInt32(h)); b.u32(UInt32(v)) }
            }
            if t.primaries != 2 || t.transfer != 2 || t.matrix != 2 {
                b.box("colr") { b in
                    b.fourcc("nclx")
                    b.u16(UInt16(clamping: t.primaries))
                    b.u16(UInt16(clamping: t.transfer))
                    b.u16(UInt16(clamping: t.matrix))
                    b.u8(t.colourRange == 2 ? 0x80 : 0)
                }
            }
        }
        return b.bytes
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(a, 1) : gcd(b, a % b) }
}

/// Reads big-endian bit fields.
struct BitReader {
    let bytes: [UInt8]
    var position = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func read(_ count: Int) -> Int {
        var v = 0
        for _ in 0..<count {
            let byte = position / 8
            let bit = byte < bytes.count ? Int(bytes[byte] >> (7 - UInt8(position % 8))) & 1 : 0
            v = v << 1 | bit
            position += 1
        }
        return v
    }

    mutating func skip(_ count: Int) { position += count }
    var bitsLeft: Int { bytes.count * 8 - position }
}

struct AACConfig {
    var objectType = 0, sampleRate = 0, channels = 0

    init?(_ asc: Data) {
        var r = BitReader(asc)
        objectType = r.read(5)
        if objectType == 31 { objectType = 32 + r.read(6) }
        let index = r.read(4)
        sampleRate = index == 15 ? r.read(24) : (index < SampleEntries.aacRates.count ? SampleEntries.aacRates[index] : 0)
        channels = r.read(4)
        if sampleRate == 0 { return nil }
    }
}

struct AC3Header {
    var fscod = 0, bsid = 0, bsmod = 0, acmod = 0, lfeon = 0, bitRateCode = 0

    static let channelCounts = [2, 1, 2, 3, 3, 4, 4, 5]
    var channels: Int { AC3Header.channelCounts[acmod] + lfeon }
    var sampleRate: Int { [48000, 44100, 32000, 48000][fscod] }

    init?(_ frame: Data) {
        var r = BitReader(frame)
        guard r.read(16) == 0x0B77 else { return nil }
        r.skip(16)  // crc1
        fscod = r.read(2)
        bitRateCode = r.read(6) >> 1
        bsid = r.read(5)
        bsmod = r.read(3)
        acmod = r.read(3)
        if acmod & 1 != 0 && acmod != 1 { r.skip(2) }
        if acmod & 4 != 0 { r.skip(2) }
        if acmod == 2 { r.skip(2) }
        lfeon = r.read(1)
        if bsid > 10 { return nil }
    }
}

struct EAC3Header {
    var fscod = 0, sampleRate = 48000, acmod = 0, lfeon = 0, bsid = 16, kbps = 0, dependentSubstreams = 0

    var channels: Int { AC3Header.channelCounts[acmod] + lfeon }

    init?(_ frame: Data) {
        var r = BitReader(frame)
        guard r.read(16) == 0x0B77 else { return nil }
        r.skip(5)   // strmtyp, substreamid
        let frameBytes = (r.read(11) + 1) * 2
        fscod = r.read(2)
        var blocks = 6
        if fscod == 3 {
            sampleRate = [24000, 22050, 16000, 48000][r.read(2)]
        } else {
            sampleRate = [48000, 44100, 32000, 48000][fscod]
            blocks = [1, 2, 3, 6][r.read(2)]
        }
        acmod = r.read(3)
        lfeon = r.read(1)
        bsid = r.read(5)
        kbps = frameBytes * 8 * sampleRate / (blocks * 256) / 1000
        dependentSubstreams = EAC3Header.frames(in: frame).filter { $0.type == 1 }.count
    }

    /// The syncframes packed into one Matroska frame: (stream type, audio samples).
    static func frames(in data: Data) -> [(type: Int, samples: Int)] {
        let bytes = Array(data)
        var out: [(Int, Int)] = []
        var p = 0
        while p + 6 <= bytes.count, bytes[p] == 0x0B, bytes[p + 1] == 0x77 {
            let type = Int(bytes[p + 2] >> 6)
            let size = ((Int(bytes[p + 2] & 0x07) << 8) | Int(bytes[p + 3])) + 1
            let fscod = Int(bytes[p + 4] >> 6)
            let blocks = fscod == 3 ? 6 : [1, 2, 3, 6][Int(bytes[p + 4] >> 4) & 3]
            out.append((type, blocks * 256))
            p += size * 2
        }
        return out
    }

    static func samples(in data: Data) -> Int? {
        let independent = frames(in: data).filter { $0.type != 1 }
        return independent.isEmpty ? nil : independent.reduce(0) { $0 + $1.samples }
    }
}

/// The bits of a VP9 keyframe header that vpcC needs.
struct VP9Header {
    var profile = 0, bitDepth = 8, chroma = 1, fullRange = 0, colorSpace = 0

    init?(_ frame: Data) {
        var r = BitReader(frame)
        guard r.read(2) == 2 else { return nil }   // frame marker
        let low = r.read(1)
        profile = r.read(1) << 1 | low
        if profile == 3 { r.skip(1) }
        guard r.read(1) == 0, r.read(1) == 0 else { return nil }   // not show-existing, keyframe
        r.skip(2)
        guard r.read(24) == 0x498342 else { return nil }
        if profile >= 2 { bitDepth = r.read(1) == 1 ? 12 : 10 }
        colorSpace = r.read(3)
        var subX = 1, subY = 1
        if colorSpace != 7 {
            fullRange = r.read(1)
            if profile == 1 || profile == 3 { subX = r.read(1); subY = r.read(1) }
        } else {
            fullRange = 1
            subX = 0; subY = 0
        }
        chroma = subX == 1 && subY == 1 ? 1 : subX == 1 ? 2 : 3
    }

    /// Primaries, transfer and matrix implied by the color space field.
    var colour: (primaries: Int, transfer: Int, matrix: Int) {
        switch colorSpace {
        case 1, 3: return (6, 6, 6)       // BT.601 / SMPTE 170
        case 2: return (1, 1, 1)          // BT.709
        case 4: return (7, 7, 7)          // SMPTE 240
        case 5: return (9, 14, 9)         // BT.2020
        case 7: return (1, 13, 0)         // sRGB
        default: return (2, 2, 2)
        }
    }
}

/// STREAMINFO from a Matroska FLAC CodecPrivate ("fLaC" + metadata blocks).
struct FLACInfo {
    var streamInfo = Data()
    var minBlock = 0, maxBlock = 0, sampleRate = 0, channels = 0

    init?(_ cp: Data) {
        let bytes = Array(cp)
        var p = bytes.starts(with: Array("fLaC".utf8)) ? 4 : 0
        while p + 4 <= bytes.count {
            let type = bytes[p] & 0x7F
            let length = Int(bytes[p + 1]) << 16 | Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
            if type == 0, length >= 34, p + 4 + length <= bytes.count {
                streamInfo = Data(bytes[(p + 4)..<(p + 4 + length)])
                break
            }
            p += 4 + length
        }
        guard !streamInfo.isEmpty else { return nil }
        var r = BitReader(streamInfo)
        minBlock = r.read(16)
        maxBlock = r.read(16)
        r.skip(48)
        sampleRate = r.read(20)
        channels = r.read(3) + 1
        if sampleRate == 0 || maxBlock == 0 { return nil }
    }

    /// Block size from a FLAC frame header.
    static func blockSize(_ frame: Data) -> Int? {
        let b = Array(frame.prefix(16))
        guard b.count >= 6, b[0] == 0xFF, b[1] & 0xFE == 0xF8 else { return nil }
        let code = Int(b[2] >> 4)
        // Skip the UTF-8 style coded frame number to reach the optional size bytes.
        var p = 4
        let lead = b[p]
        p += lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : lead < 0xF8 ? 4 : lead < 0xFC ? 5 : lead < 0xFE ? 6 : 7
        switch code {
        case 1: return 192
        case 2...5: return 576 << (code - 2)
        case 6: return p < b.count ? Int(b[p]) + 1 : nil
        case 7: return p + 1 < b.count ? (Int(b[p]) << 8 | Int(b[p + 1])) + 1 : nil
        case 8...15: return 256 << (code - 8)
        default: return nil
        }
    }
}

/// The OpusHead header Matroska stores in CodecPrivate (little-endian fields).
struct OpusHead {
    var channels = 2, preSkip = 0, inputRate = 48000, gain = 0, family = 0
    var mapping = Data()

    init?(_ cp: Data) {
        let b = Array(cp)
        guard b.count >= 19, b.starts(with: Array("OpusHead".utf8)) else { return nil }
        channels = Int(b[9])
        preSkip = Int(b[10]) | Int(b[11]) << 8
        inputRate = Int(b[12]) | Int(b[13]) << 8 | Int(b[14]) << 16 | Int(b[15]) << 24
        gain = Int(Int16(bitPattern: UInt16(b[16]) | UInt16(b[17]) << 8))
        family = Int(b[18])
        if family != 0 {
            guard b.count >= 21 + channels else { return nil }
            mapping = Data(b[19..<(21 + channels)])
        }
    }

    /// Samples at 48 kHz in one Opus packet, from its TOC byte.
    static func samples(in packet: Data) -> Int {
        guard let toc = packet.first else { return 960 }
        let config = Int(toc >> 3)
        let frame = config < 12 ? [480, 960, 1920, 2880][config % 4]
            : config < 16 ? [480, 960][config % 2]
            : [120, 240, 480, 960][config % 4]
        switch toc & 3 {
        case 0: return frame
        case 1, 2: return frame * 2
        default: return packet.count > 1 ? frame * Int(packet[packet.startIndex + 1] & 0x3F) : frame
        }
    }
}
