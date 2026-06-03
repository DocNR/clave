import XCTest
@testable import Clave

/// Tests for `NIP44v3.Padding.targetSize(forLength:)`.
///
/// Validates the padding algorithm against all 176 padded_length test vectors
/// from the NIP-44 v3 spec test-vectors.json (commit 5680754, 2026-06-02).
final class NIP44v3PaddingTests: XCTestCase {

    // MARK: - Spec test vectors

    /// 176 [unpadded, padded] pairs from `nostr-land/nip44v3@5680754` test-vectors.json.
    /// Embedded inline to avoid Bundle-resource setup for this first port; future
    /// PRs porting encrypt/decrypt vectors should switch to a JSON fixture file.
    private static let specVectors: [(unpadded: Int, padded: Int)] = [
        (0, 32), (1, 32), (32, 32), (33, 64),
        (34, 64), (64, 64), (65, 96), (66, 96),
        (96, 96), (97, 128), (98, 128), (128, 128),
        (129, 192), (130, 192), (192, 192), (193, 256),
        (194, 256), (256, 256), (257, 384), (258, 384),
        (384, 384), (385, 512), (386, 512), (512, 512),
        (513, 768), (514, 768), (768, 768), (769, 1024),
        (770, 1024), (1024, 1024), (1025, 1536), (1026, 1536),
        (1536, 1536), (1537, 2048), (1538, 2048), (2048, 2048),
        (2049, 3072), (2050, 3072), (3072, 3072), (3073, 4096),
        (3074, 4096), (4096, 4096), (4097, 6144), (4098, 6144),
        (6144, 6144), (6145, 8192), (6146, 8192), (8192, 8192),
        (8193, 12288), (8194, 12288), (12288, 12288), (12289, 16384),
        (12290, 16384), (16384, 16384), (16385, 20480), (16386, 20480),
        (20480, 20480), (20481, 24576), (20482, 24576), (24576, 24576),
        (24577, 28672), (24578, 28672), (28672, 28672), (28673, 32768),
        (28674, 32768), (32768, 32768), (32769, 40960), (32770, 40960),
        (40960, 40960), (40961, 49152), (40962, 49152), (49152, 49152),
        (49153, 57344), (49154, 57344), (57344, 57344), (57345, 65536),
        (57346, 65536), (65536, 65536), (65537, 81920), (65538, 81920),
        (81920, 81920), (81921, 98304), (81922, 98304), (98304, 98304),
        (98305, 114688), (98306, 114688), (114688, 114688), (114689, 131072),
        (114690, 131072), (131072, 131072), (131073, 163840), (131074, 163840),
        (163840, 163840), (163841, 196608), (163842, 196608), (196608, 196608),
        (196609, 229376), (196610, 229376), (229376, 229376), (229377, 262144),
        (229378, 262144), (262144, 262144), (262145, 327680), (262146, 327680),
        (327680, 327680), (327681, 393216), (327682, 393216), (393216, 393216),
        (393217, 458752), (393218, 458752), (458752, 458752), (458753, 524288),
        (458754, 524288), (524288, 524288), (524289, 655360), (524290, 655360),
        (655360, 655360), (655361, 786432), (655362, 786432), (786432, 786432),
        (786433, 917504), (786434, 917504), (917504, 917504), (917505, 1048576),
        (917506, 1048576), (1048576, 1048576), (1048577, 1310720), (1048578, 1310720),
        (1310720, 1310720), (1310721, 1572864), (1310722, 1572864), (1572864, 1572864),
        (1572865, 1835008), (1572866, 1835008), (1835008, 1835008), (1835009, 2097152),
        (1835010, 2097152), (2097152, 2097152), (2097153, 2621440), (2097154, 2621440),
        (2621440, 2621440), (2621441, 3145728), (2621442, 3145728), (3145728, 3145728),
        (3145729, 3670016), (3145730, 3670016), (3670016, 3670016), (3670017, 4194304),
        (3670018, 4194304), (4194304, 4194304), (4194305, 5242880), (4194306, 5242880),
        (5242880, 5242880), (5242881, 6291456), (5242882, 6291456), (6291456, 6291456),
        (6291457, 7340032), (6291458, 7340032), (7340032, 7340032), (7340033, 8388608),
        (7340034, 8388608), (8388608, 8388608), (8388609, 10485760), (8388610, 10485760),
        (10485760, 10485760), (10485761, 12582912), (10485762, 12582912), (12582912, 12582912),
        (12582913, 14680064), (12582914, 14680064), (14680064, 14680064), (14680065, 16777216),
        (14680066, 16777216), (16777216, 16777216), (16777217, 20971520), (16777218, 20971520),
    ]

    // MARK: - Bulk spec compliance

    /// All 176 spec vectors must match exactly. This is the primary correctness test.
    func testTargetSizeMatchesAllSpecVectors() {
        var failures: [String] = []
        for (unpadded, expected) in Self.specVectors {
            let actual = NIP44v3.Padding.targetSize(forLength: unpadded)
            if actual != expected {
                failures.append("targetSize(\(unpadded)) = \(actual), expected \(expected)")
            }
        }
        XCTAssertTrue(
            failures.isEmpty,
            "\(failures.count) / \(Self.specVectors.count) spec vectors failed:\n" +
            failures.prefix(10).joined(separator: "\n")
        )
    }

    // MARK: - Documented edge cases

    /// Spec: "For `len = 0`, the padded length is `minimum_size`."
    func testTargetSizeForZeroReturnsMinimum() {
        XCTAssertEqual(NIP44v3.Padding.targetSize(forLength: 0), NIP44v3.Padding.minimumSize)
    }

    /// Spec invariant: the target size is never less than `minimum_size`.
    /// Tested at the boundary and just above.
    func testTargetSizeNeverReturnsLessThanMinimum() {
        for len in 0...64 {
            let result = NIP44v3.Padding.targetSize(forLength: len)
            XCTAssertGreaterThanOrEqual(
                result, NIP44v3.Padding.minimumSize,
                "targetSize(\(len)) = \(result) < minimum (\(NIP44v3.Padding.minimumSize))"
            )
        }
    }

    /// Sanity property: target size is monotonically non-decreasing in input length.
    /// If A <= B then targetSize(A) <= targetSize(B).
    func testTargetSizeIsMonotonicallyNonDecreasing() {
        var previous = 0
        for (unpadded, _) in Self.specVectors {
            let current = NIP44v3.Padding.targetSize(forLength: unpadded)
            XCTAssertGreaterThanOrEqual(
                current, previous,
                "Monotonicity violated at len=\(unpadded): \(current) < previous \(previous)"
            )
            previous = current
        }
    }

    /// Boundary: at the small/large chunk threshold (32768 bytes), behavior switches
    /// from 4-way to 8-way subdivision. Verify both sides match spec vectors.
    func testChunkSubdivThresholdBoundary() {
        // Just under threshold: next_power = 32768, chunk_subdivs = 4 (still small bucket)
        XCTAssertEqual(NIP44v3.Padding.targetSize(forLength: 28674), 32768)
        XCTAssertEqual(NIP44v3.Padding.targetSize(forLength: 32768), 32768)
        // Just over: next_power = 65536, chunk_subdivs = 8 (large bucket)
        XCTAssertEqual(NIP44v3.Padding.targetSize(forLength: 32769), 40960)
        XCTAssertEqual(NIP44v3.Padding.targetSize(forLength: 40960), 40960)
    }
}
