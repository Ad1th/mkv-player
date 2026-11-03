import Foundation

/// Builds stsd entries for the codecs AVFoundation can decode.
enum SampleEntries {
    static func video(_ t: MatroskaTrack, width: Int, height: Int) -> [UInt8]? {
        let cp = t.codecPrivate
        switch t.codec {
        case "V_MPEG4/ISO/AVC" where cp.count > 6:
            return visual("avc1", t, width, height) { $0.box("avcC") { $0.append(cp) } }
        case "V_MPEGH/ISO/HEVC" where cp.count > 22:
            return visual("hvc1", t, width, height) { $0.box("hvcC") { $0.append(cp) } }
        default:
            return nil
        }
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
