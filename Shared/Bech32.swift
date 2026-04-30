import Foundation

enum Bech32 {
    private static let charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

    static func decode(_ str: String) throws -> (hrp: String, data: Data) {
        let lower = str.lowercased()
        guard let sepIndex = lower.lastIndex(of: "1") else {
            throw Bech32Error.noSeparator
        }

        let hrp = String(lower[lower.startIndex..<sepIndex])
        let dataStr = String(lower[lower.index(after: sepIndex)...])

        guard dataStr.count >= 6 else { throw Bech32Error.tooShort }

        var values: [UInt8] = []
        for c in dataStr {
            guard let idx = charset.firstIndex(of: c) else {
                throw Bech32Error.invalidCharacter
            }
            values.append(UInt8(charset.distance(from: charset.startIndex, to: idx)))
        }

        let data5bit = Array(values.dropLast(6))
        let bytes = try convertBits(data: data5bit, fromBits: 5, toBits: 8, pad: false)
        return (hrp, Data(bytes))
    }

    static func decodeNsec(_ nsec: String) throws -> Data {
        let (hrp, data) = try decode(nsec)
        guard hrp == "nsec" else { throw Bech32Error.invalidHRP(hrp) }
        guard data.count == 32 else { throw Bech32Error.invalidLength(data.count) }
        return data
    }

    /// Encode raw bytes with the given HRP. Inverse of `decode`.
    /// Used by NIP-19 to build `npub`, `note`, `nevent`, etc.
    static func encode(hrp: String, data: Data) throws -> String {
        let lowerHrp = hrp.lowercased()
        let bytes5 = try convertBits(data: Array(data), fromBits: 8, toBits: 5, pad: true)
        let checksum = createChecksum(hrp: lowerHrp, data: bytes5)
        let combined = bytes5 + checksum
        var payload = ""
        for v in combined {
            let idx = charset.index(charset.startIndex, offsetBy: Int(v))
            payload.append(charset[idx])
        }
        return "\(lowerHrp)1\(payload)"
    }

    // MARK: - Polymod / checksum (BIP-173)

    private static let generator: [UInt32] = [
        0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3
    ]

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = ((chk & 0x1ffffff) << 5) ^ UInt32(v)
            for i in 0..<5 where ((top >> i) & 1) == 1 {
                chk ^= generator[i]
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var ret: [UInt8] = []
        for c in hrp.unicodeScalars {
            ret.append(UInt8(c.value >> 5))
        }
        ret.append(0)
        for c in hrp.unicodeScalars {
            ret.append(UInt8(c.value & 31))
        }
        return ret
    }

    private static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        var ret: [UInt8] = []
        for i in 0..<6 {
            ret.append(UInt8((mod >> (5 * (5 - i))) & 31))
        }
        return ret
    }

    private static func convertBits(data: [UInt8], fromBits: Int, toBits: Int, pad: Bool) throws -> [UInt8] {
        var acc: Int = 0
        var bits: Int = 0
        var result: [UInt8] = []
        let maxV = (1 << toBits) - 1

        for value in data {
            let v = Int(value)
            if v < 0 || (v >> fromBits) != 0 {
                throw Bech32Error.invalidData
            }
            acc = (acc << fromBits) | v
            bits += fromBits
            while bits >= toBits {
                bits -= toBits
                result.append(UInt8((acc >> bits) & maxV))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (toBits - bits)) & maxV))
            }
        } else if bits >= fromBits || ((acc << (toBits - bits)) & maxV) != 0 {
            throw Bech32Error.invalidPadding
        }

        return result
    }
}

enum Bech32Error: LocalizedError {
    case noSeparator
    case tooShort
    case invalidCharacter
    case invalidHRP(String)
    case invalidLength(Int)
    case invalidData
    case invalidPadding

    var errorDescription: String? {
        switch self {
        case .noSeparator: return "No bech32 separator found"
        case .tooShort: return "Bech32 data too short"
        case .invalidCharacter: return "Invalid bech32 character"
        case .invalidHRP(let h): return "Expected 'nsec' HRP, got '\(h)'"
        case .invalidLength(let l): return "Expected 32 bytes, got \(l)"
        case .invalidData: return "Invalid bech32 data"
        case .invalidPadding: return "Invalid bech32 padding"
        }
    }
}
