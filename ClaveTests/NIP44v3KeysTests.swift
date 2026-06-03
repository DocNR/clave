import XCTest
import P256K
@testable import Clave

/// Tests for `NIP44v3.Keys.derive(seckey:pubkey:nonce:)`.
///
/// Validates HKDF-Extract / HKDF-Expand key derivation against all 10
/// `encrypt_decrypt` test vectors from the NIP-44 v3 spec test-vectors.json
/// (commit 5680754, 2026-06-02). ECDH is symmetric, so each vector is run
/// twice — once from each party's perspective — for 20 total derivations.
final class NIP44v3KeysTests: XCTestCase {

    // MARK: - Spec test vectors

    private struct EncryptDecryptVector {
        let secret1: String
        let secret2: String
        let nonce: String
        let prk: String
        let encryptionKey: String
        let macKey: String
    }

    /// 10 vectors from `nostr-land/nip44v3@5680754` test-vectors.json,
    /// `encrypt_decrypt` array. Only the fields the Keys layer consumes
    /// or asserts on are kept here — `kind`, `scope_hex`, `plaintext_hex`,
    /// and `ciphertext` are exercised by the upcoming Encryption +
    /// Ciphertext layers.
    private static let specVectors: [EncryptDecryptVector] = [
        .init(
            secret1: "1b7023bb70248d8edab44658c5e2677dd7e5d7093ec062eb204975df4255fddc",
            secret2: "827844538be12d1cfa0f7fa096668cc4f2c4a25c2c8f7e92ca6cb05c3c445d17",
            nonce:   "b5451a6d90ec575b4cdcedf4987429eeab1bbaa192ea3db89eafa058826885a6",
            prk:           "3520160171dc39d75e64768d4fb667647480d458fc4d5c26d000a7cb3c8805b1",
            encryptionKey: "de94e4663af538351a9b75b8af31e968ed8b88241ddbce43ad1d4ae2b984327d",
            macKey:        "70e65d5ff8769e92fbdf163b00b1b317bd4d30fe82de6b00d05cd74fb576febd"
        ),
        .init(
            secret1: "f9869a8237c9fffd3bc175d21cc144051de4889da28b462ca1e4557adc2d2275",
            secret2: "c4c53829b9ad83682873761b71d667457935eaa84159a206dea58f18be09d05d",
            nonce:   "f99a4a4a84a4906d839b62861dcd54883cccabb3616d003f27250ac00e672c50",
            prk:           "7eeee2eac804eae839f64c4f2204ba6c205a65ae895bea006a45afd2ff9afee0",
            encryptionKey: "56c727b1f69ff6ecb29c6cfd6469c1908da5556b0c13123b3303d5068edf03b6",
            macKey:        "f6be43893bffe64c43d56ee2692014d3e5275a78a3cd8268e2e1e0cb707a6bad"
        ),
        .init(
            secret1: "2f69dcb9891cf749ab0b4e07a718a9e364c44e7603d851c7c09e080b631534fb",
            secret2: "110ffc1f2ea8b15ffd5d24c59dc1b72c4b1f8180dd5ccb6a68097ff328f49e54",
            nonce:   "ffffd9144f5fe48077ac672e1366d303dfebdf60b1abd07fce1ff762bb25a4aa",
            prk:           "dd23c1dad51c025ed632be8b8da198517eef83a86729ccf524382f6011c9500b",
            encryptionKey: "44f5de03559045aeb509d670299e7eab7f12682a7d5cc6c9a1441fd35f9484a9",
            macKey:        "ab08e3aa28d40c9376a56056dea33b3e935402da5585607b081ad166cecd8432"
        ),
        .init(
            secret1: "e945941c87478b88c8af150219ed8055692f3f01543a3dec3cb40854fdf8545b",
            secret2: "11eefd6b9a1a4d4e4b71840aa77eb47d3821d825ca8d4e45065ff563bdc342d9",
            nonce:   "726cab7f363afe8c0783dc1d2d6e4700ace52a26996a53ba3928ef3c865cc235",
            prk:           "7fafc5865086ba6ef1d48c93fa5e8c84dc0fd73924f23a4560d8d0f31f9ab2db",
            encryptionKey: "2b6ed20127afba197082b52159120042d0bdfec6df2e657944f79a62ec90a1d0",
            macKey:        "2e72490f486fd6f0ed2ca5e508dff16b6db6936df59b77406717e6aed645d2a0"
        ),
        .init(
            secret1: "98c7c39a4abf5f923db71a3e2c0951fa020bc5ba1555c158ebc8663e1582bb01",
            secret2: "b775d4f4ef14b1a93cc34a534a64a1ec2cd1a64a5a7b45f837af5ea4595b37dc",
            nonce:   "ec64f769d99bc3c6f5231145b546334275d910e11fe9a11351ee487e4dbfd4ec",
            prk:           "98fca3e635b9478407385a8989fb78ddb115d992a92019852953a4cd139aeb69",
            encryptionKey: "9e6bdba691401f02de1403f75ebcb3516f5ff3b77c8a3918d8a3393e73eb3188",
            macKey:        "b05399edc9e6eae42cc21ec5941a73e8b7387bf10f49dfcfd740131309d81c35"
        ),
        .init(
            secret1: "b0e73a57d65972a4276879cb8604f683dfd9197cc236f299ea55acb66bfa8ff0",
            secret2: "ebf87d9858227055ac9f789911edad1b55777edc99dd4b8634f52bb8c0922edc",
            nonce:   "c027624d50656a34add75cec7e476e6287bc919cacf0ebbda6d3277c02b0a239",
            prk:           "a76ecc57266a24238761cf79c9909e27af6adfa523fb914a1a54e17d15e26287",
            encryptionKey: "3c5be4141db8d4e4bfd998b6a4f995922070b9dc4af41c5d50c89c7ccd437f0e",
            macKey:        "92704765cd32cbe3beb21f347541184fc0cff839c8d2077d198d1f91103bdd22"
        ),
        .init(
            secret1: "0bac57d63af3e6650152577f7d5515062270b68cd2cda1250604ab70b7cdf091",
            secret2: "ddb09a891ef13bbf1b9ed8fb403afce4eea2197428da805dc85d90eee76e20f2",
            nonce:   "0da18d3ebcc5f269f6415e3e3fcb5e1a8d76318fe439ec83cfdf99ef8eaacee9",
            prk:           "d084d04cb7e61bb0c8fc7fbfaf48b58863fc01c1a4cebc7d48cad3b3853ac7a7",
            encryptionKey: "be6eb2e4aa213dc2260abc2414e763057ab7df785e33338f1a3167ac280ee7fb",
            macKey:        "59f55d61316dee4f7f71c7b3d9704ef822d5d31bcfda30d02a267f29cb20d92e"
        ),
        .init(
            secret1: "b69f38d981ad22b1fd25473756b2dd9c69d1554c6d31ae2a64c0fc82aafd86ac",
            secret2: "c916f18fd08a90c1d20bdfe27f31c53d33ebefdbe28e3da8797632b4b474b9df",
            nonce:   "8b3c3f3aaf575328259ac5e3c08191dde308c573e3f4e7cda7042f82133143fb",
            prk:           "93c97bd637c3fc60d9dbdb410df34c4a614c52db57ed0f2a218e8a973e125265",
            encryptionKey: "e0a45a9306cc404aea91687e2b3c26abe23b0e12945799279e332c1880cacd78",
            macKey:        "b21748a15b40d53bbdaeb81c419c160994780d141324fcb1ac65bcd8be6bb6f4"
        ),
        .init(
            secret1: "20d7e7e95a8e6376438182425c33c9445055fa4a8bd2c57e5c7902015433e18d",
            secret2: "d38139efe4118dd5862c2556600ef7914d1659cabbd1a3d5fd9f2a0abe9dcbb3",
            nonce:   "20c635f2f795178ea0bbf9856dd99da02138ba79337d2511d887f2a065b917c9",
            prk:           "4f9c75fe7c850a79f83000901ef8f020301c06e413a84de01784971ec249bb7b",
            encryptionKey: "4345c818ddb2793427d8f5bb056e663cd941f910165601ff6806866cb7fb0fc3",
            macKey:        "4eb9ee0ea464574336446a8aae961f05b6a65cd5feb2087417eabf5344c554da"
        ),
        .init(
            secret1: "1a2c6e81b5f1038fdda1f555d0431d1bd3efb22d57f608708fa46d7d7b96f1f5",
            secret2: "c18596eac499c94e04334021c1b6952757d83aeda2aa84f90ab47357cdd29fdb",
            nonce:   "a05a11dcd50aa1e855b7e11a816158a1a4827d21a00b60105ed3c8e802770d77",
            prk:           "c043b08590fcc2ef03e299633af842deffd1b5dbd2bf598606bf02abb898303d",
            encryptionKey: "ba927e27a656a34369920ce7be028b6f6cb5878890123d1d3ba6b9f7ef4ab9c4",
            macKey:        "71163bde93ea8fa3b5574e81869416bcb8f6954a3b746e1b2ed24546949e208c"
        ),
    ]

    // MARK: - Per-perspective derivation

    /// For every vector, derive from `sec1`'s perspective and compare against
    /// the expected `prk`, `encryption_key`, `mac_key`.
    func testDeriveMatchesSpecFromSecret1Perspective() throws {
        var failures: [String] = []
        for (i, vec) in Self.specVectors.enumerated() {
            do {
                let derived = try deriveFromPerspective(localSecret: vec.secret1, remoteSecret: vec.secret2, nonceHex: vec.nonce)
                accumulateMismatches(index: i, side: "sec1", derived: derived, expected: vec, into: &failures)
            } catch {
                failures.append("vec[\(i)] sec1: threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty,
            "\(failures.count) sec1-perspective derivations failed:\n" +
            failures.prefix(10).joined(separator: "\n"))
    }

    /// ECDH is symmetric, so from `sec2`'s perspective the keys must match
    /// the same expected values.
    func testDeriveMatchesSpecFromSecret2Perspective() throws {
        var failures: [String] = []
        for (i, vec) in Self.specVectors.enumerated() {
            do {
                let derived = try deriveFromPerspective(localSecret: vec.secret2, remoteSecret: vec.secret1, nonceHex: vec.nonce)
                accumulateMismatches(index: i, side: "sec2", derived: derived, expected: vec, into: &failures)
            } catch {
                failures.append("vec[\(i)] sec2: threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty,
            "\(failures.count) sec2-perspective derivations failed:\n" +
            failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - Edge cases

    /// The salt prefix MUST be exactly `"nip44-v3" + 0x00` — 9 bytes total.
    /// An easy bug is to drop the trailing NUL or substitute a space.
    func testSaltPrefixIsExactly9BytesWithTrailingNUL() {
        let prefix = NIP44v3.Keys.saltPrefix
        XCTAssertEqual(prefix.count, 9)
        XCTAssertEqual(Array(prefix), [0x6e, 0x69, 0x70, 0x34, 0x34, 0x2d, 0x76, 0x33, 0x00])
    }

    /// Inputs of wrong length must throw the corresponding error rather than
    /// silently truncate / pad.
    func testDeriveRejectsWrongLengthInputs() {
        let okSeckey = Data(repeating: 0x01, count: 32)
        let okPubkey = Data(repeating: 0x02, count: 32)
        let okNonce  = Data(repeating: 0x03, count: 32)

        XCTAssertThrowsError(try NIP44v3.Keys.derive(seckey: Data(count: 31), pubkey: okPubkey, nonce: okNonce))
        XCTAssertThrowsError(try NIP44v3.Keys.derive(seckey: okSeckey,         pubkey: Data(count: 31), nonce: okNonce))
        XCTAssertThrowsError(try NIP44v3.Keys.derive(seckey: okSeckey,         pubkey: okPubkey,        nonce: Data(count: 31)))
    }

    // MARK: - Helpers

    private func deriveFromPerspective(
        localSecret: String,
        remoteSecret: String,
        nonceHex: String
    ) throws -> NIP44v3.Keys.Derived {
        guard let seckey = Data(hexString: localSecret),
              let remoteSec = Data(hexString: remoteSecret),
              let nonce = Data(hexString: nonceHex) else {
            throw NSError(domain: "NIP44v3KeysTests", code: 1)
        }
        let remotePub = try Self.xOnlyPublicKey(forSecret: remoteSec)
        return try NIP44v3.Keys.derive(seckey: seckey, pubkey: remotePub, nonce: nonce)
    }

    /// BIP-340 x-only public key (32 bytes) from a 32-byte secret. Mirrors
    /// the ECDH input shape that the spec assumes.
    private static func xOnlyPublicKey(forSecret seckey: Data) throws -> Data {
        let priv = try P256K.Schnorr.PrivateKey(dataRepresentation: seckey)
        return Data(priv.xonly.bytes)
    }

    private func accumulateMismatches(
        index: Int,
        side: String,
        derived: NIP44v3.Keys.Derived,
        expected: EncryptDecryptVector,
        into failures: inout [String]
    ) {
        if derived.prk.hex != expected.prk {
            failures.append("vec[\(index)] \(side) prk: got \(derived.prk.hex), want \(expected.prk)")
        }
        if derived.encryptionKey.hex != expected.encryptionKey {
            failures.append("vec[\(index)] \(side) enc: got \(derived.encryptionKey.hex), want \(expected.encryptionKey)")
        }
        if derived.macKey.hex != expected.macKey {
            failures.append("vec[\(index)] \(side) mac: got \(derived.macKey.hex), want \(expected.macKey)")
        }
    }
}
