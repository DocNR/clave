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
