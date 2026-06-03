import XCTest
import CryptoKit
import P256K
@testable import Clave

/// Tests for `NIP44v3.Encryption.encrypt(...)` and `.decrypt(...)`.
///
/// Validates ChaCha20 + HMAC-SHA256 wrap against the NIP-44 v3 spec
/// test-vectors.json at commit `5680754` (2026-06-02). Four categories
/// of vector are exercised:
///
/// 1. `encrypt_decrypt` (10) — round-trip in both directions. Pre-derived
///    keys are taken directly from the JSON, so this validates the
///    Encryption layer in isolation from the Keys layer.
/// 2. `decrypt_only` (5)    — non-standard padding lengths. **These exist
///    specifically to catch the Amber-PR-#448 gotcha** of recomputing
///    `target_size(plaintext_len)` and comparing to the actual padded
///    length. Spec commit `c6daedd` says implementations MUST NOT do
///    that — only the all-zeros check is required.
/// 3. `long_encrypt_decrypt` (18) — large messages (`pattern × repeat`).
///    Expected SHA-256 of the full wire is checked.
/// 4. `invalid_decryption` (8 subset, indices 0/1/2/3/14/15/16/17) — the
///    encryption-layer subset: MAC tampering, padding tampering, kind
///    mismatch, scope mismatch. Skipped indices (4–13, 18) test ciphertext-
///    layer / Context-layer concerns and are deferred to those chips.
final class NIP44v3EncryptionTests: XCTestCase {

    // MARK: - Vector types

    private struct EncryptDecryptVector {
        let secret1, secret2, nonce: String
        let kind: UInt32
        let scopeHex: String
        let prk, encryptionKey, macKey: String
        let plaintextHex: String
        let ciphertextB64: String
    }

    private struct DecryptOnlyVector {
        let nonce: String
        let kind: UInt32
        let scopeHex: String
        let encryptionKey, macKey: String
        let plaintextHex: String
        let ciphertextB64: String
        let note: String
    }

    private struct LongVector {
        let secret1, secret2, nonce: String
        let kind: UInt32
        let scopeHex: String
        let patternHex: String
        let repeatCount: Int
        let expectedCiphertextSha256: String
    }

    private struct InvalidDecryptionVector {
        let secret, publicKey: String
        let kind: UInt32
        let scopeHex: String
        let ciphertextB64: String
        let why: String
    }

    // MARK: - encrypt_decrypt vectors (10)

    private static let encryptDecryptVectors: [EncryptDecryptVector] = [
        .init(secret1: "1b7023bb70248d8edab44658c5e2677dd7e5d7093ec062eb204975df4255fddc", secret2: "827844538be12d1cfa0f7fa096668cc4f2c4a25c2c8f7e92ca6cb05c3c445d17", nonce: "b5451a6d90ec575b4cdcedf4987429eeab1bbaa192ea3db89eafa058826885a6", kind: 1, scopeHex: "", prk: "3520160171dc39d75e64768d4fb667647480d458fc4d5c26d000a7cb3c8805b1", encryptionKey: "de94e4663af538351a9b75b8af31e968ed8b88241ddbce43ad1d4ae2b984327d", macKey: "70e65d5ff8769e92fbdf163b00b1b317bd4d30fe82de6b00d05cd74fb576febd", plaintextHex: "efbbbf48656c6c6f20776f726c6421", ciphertextB64: "A7VFGm2Q7FdbTNzt9Jh0Ke6rG7qhkuo9uJ6voFiCaIWmMJrEDBNRRCorotVxmP7ge14Y+UtDn1/Pn3uzAaNNzHUAAAABAAAAAPJgoFXpn6mjFE0hUZrnZljeaYwSdqBKbVDXcyLgVGC8"),
        .init(secret1: "f9869a8237c9fffd3bc175d21cc144051de4889da28b462ca1e4557adc2d2275", secret2: "c4c53829b9ad83682873761b71d667457935eaa84159a206dea58f18be09d05d", nonce: "f99a4a4a84a4906d839b62861dcd54883cccabb3616d003f27250ac00e672c50", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", prk: "7eeee2eac804eae839f64c4f2204ba6c205a65ae895bea006a45afd2ff9afee0", encryptionKey: "56c727b1f69ff6ecb29c6cfd6469c1908da5556b0c13123b3303d5068edf03b6", macKey: "f6be43893bffe64c43d56ee2692014d3e5275a78a3cd8268e2e1e0cb707a6bad", plaintextHex: "6e6f7374722e6c616e64206e697034347633", ciphertextB64: "A/maSkqEpJBtg5tihh3NVIg8zKuzYW0APyclCsAOZyxQfHiK7t6u8D4JR3dRUKMpBRQzoOYtunePezG3p65AXPEAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzvgOo5isSBI06S531Yb9j9l+LpL9dA0D9/LLtorb866Y="),
        .init(secret1: "2f69dcb9891cf749ab0b4e07a718a9e364c44e7603d851c7c09e080b631534fb", secret2: "110ffc1f2ea8b15ffd5d24c59dc1b72c4b1f8180dd5ccb6a68097ff328f49e54", nonce: "ffffd9144f5fe48077ac672e1366d303dfebdf60b1abd07fce1ff762bb25a4aa", kind: 1, scopeHex: "e381afe4b896e7958c", prk: "dd23c1dad51c025ed632be8b8da198517eef83a86729ccf524382f6011c9500b", encryptionKey: "44f5de03559045aeb509d670299e7eab7f12682a7d5cc6c9a1441fd35f9484a9", macKey: "ab08e3aa28d40c9376a56056dea33b3e935402da5585607b081ad166cecd8432", plaintextHex: "f09f9088f09fa694", ciphertextB64: "A///2RRPX+SAd6xnLhNm0wPf699gsavQf84f92K7JaSqrm0b+bxgKBqNS04QURAmEXZlYBY9Ed4neDw2uOAqkGcAAAABAAAACeOBr+S4lueVjIEUNKR4ekMqHUoWb/ks495G0c1lD6oPQ3ZFsa4LHvRE"),
        .init(secret1: "e945941c87478b88c8af150219ed8055692f3f01543a3dec3cb40854fdf8545b", secret2: "11eefd6b9a1a4d4e4b71840aa77eb47d3821d825ca8d4e45065ff563bdc342d9", nonce: "726cab7f363afe8c0783dc1d2d6e4700ace52a26996a53ba3928ef3c865cc235", kind: 1, scopeHex: "efbbbfefbfbe", prk: "7fafc5865086ba6ef1d48c93fa5e8c84dc0fd73924f23a4560d8d0f31f9ab2db", encryptionKey: "2b6ed20127afba197082b52159120042d0bdfec6df2e657944f79a62ec90a1d0", macKey: "2e72490f486fd6f0ed2ca5e508dff16b6db6936df59b77406717e6aed645d2a0", plaintextHex: "e69a97e58fb7e58c96e381aee3819fe38281e381aee382a2e382afe382bbe382b9e588b6e5bea1e6a99fe883bde3818ce799bbe5a0b4e38197e381bee38197e3819fefbc81", ciphertextB64: "A3Jsq382Ov6MB4PcHS1uRwCs5SommWpTujko7zyGXMI1d8FRsRgcGnjOo+Ifry8x/QC+vDDkPCHv7WDaem7tQ10AAAABAAAABu+7v++/vm+/pDQcUXHli2Do1EEoqYFmF/67UUcl31Ks9TRy9vCwc2IUY6Ev9T+oBanqVWGbPgAWysjisi5dIPAEcndMK2Ur4m2UqTo3WVTIqKmy30ad5VOwl4v1AHweiZvJU/w+lQ=="),
        .init(secret1: "98c7c39a4abf5f923db71a3e2c0951fa020bc5ba1555c158ebc8663e1582bb01", secret2: "b775d4f4ef14b1a93cc34a534a64a1ec2cd1a64a5a7b45f837af5ea4595b37dc", nonce: "ec64f769d99bc3c6f5231145b546334275d910e11fe9a11351ee487e4dbfd4ec", kind: 1, scopeHex: "ef8080", prk: "98fca3e635b9478407385a8989fb78ddb115d992a92019852953a4cd139aeb69", encryptionKey: "9e6bdba691401f02de1403f75ebcb3516f5ff3b77c8a3918d8a3393e73eb3188", macKey: "b05399edc9e6eae42cc21ec5941a73e8b7387bf10f49dfcfd740131309d81c35", plaintextHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", ciphertextB64: "A+xk92nZm8PG9SMRRbVGM0J12RDhH+mhE1HuSH5Nv9Tsg6J943ljpXnIaVIuHaXrWfa99RkqZOW6NGy6oqm2HocAAAABAAAAA++AgNCkiGZgN5Uzx1HVpcoLQQisIwWD32PqBoQ4T598/KmHsxUAGEARiXh9ikGXtwKuH8a8EzTcobkr4OEXfPs0h5u0A1HUJ3M/Hc/orcqZgeA0RhfZe3IASVmQfU9/pge+nTPjJVK5ZHOlEBnt7tmYcT8vqv9bpxbyhCBGMO6nEFhUtrr2IKCW3Z6vljg7T3FDr7aVIY/cxniq4E+e5ec9pZ+wn3j9PAibWgEANCDK5nyiH6B348lnqxfmu8bvzzyPhA=="),
        .init(secret1: "b0e73a57d65972a4276879cb8604f683dfd9197cc236f299ea55acb66bfa8ff0", secret2: "ebf87d9858227055ac9f789911edad1b55777edc99dd4b8634f52bb8c0922edc", nonce: "c027624d50656a34add75cec7e476e6287bc919cacf0ebbda6d3277c02b0a239", kind: 1, scopeHex: "", prk: "a76ecc57266a24238761cf79c9909e27af6adfa523fb914a1a54e17d15e26287", encryptionKey: "3c5be4141db8d4e4bfd998b6a4f995922070b9dc4af41c5d50c89c7ccd437f0e", macKey: "92704765cd32cbe3beb21f347541184fc0cff839c8d2077d198d1f91103bdd22", plaintextHex: "6120646563656e7472616c697a65642070726f746f636f6c20666f7220616e797468696e67", ciphertextB64: "A8AnYk1QZWo0rddc7H5HbmKHvJGcrPDrvabTJ3wCsKI5ZMf+aMW7P7Iz5qDghY+87TL5pZjNiykm0xpMKlkwITgAAAABAAAAAE2F94qgXOR+co8R41Vu04wLtkrI3Y5QJbVmutA5v1MkCgrLCmZAwNXhQsUnzUOuAPloXVQQdgQL4gmVgIz0rqQ="),
        .init(secret1: "0bac57d63af3e6650152577f7d5515062270b68cd2cda1250604ab70b7cdf091", secret2: "ddb09a891ef13bbf1b9ed8fb403afce4eea2197428da805dc85d90eee76e20f2", nonce: "0da18d3ebcc5f269f6415e3e3fcb5e1a8d76318fe439ec83cfdf99ef8eaacee9", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", prk: "d084d04cb7e61bb0c8fc7fbfaf48b58863fc01c1a4cebc7d48cad3b3853ac7a7", encryptionKey: "be6eb2e4aa213dc2260abc2414e763057ab7df785e33338f1a3167ac280ee7fb", macKey: "59f55d61316dee4f7f71c7b3d9704ef822d5d31bcfda30d02a267f29cb20d92e", plaintextHex: "efbbbf48656c6c6f20776f726c6421", ciphertextB64: "Aw2hjT68xfJp9kFePj/LXhqNdjGP5Dnsg8/fme+Oqs7p+xyexXUdk8ZJ2rtLWT1xQ9lXxWSiagEVpRg35PndmKQAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzuKZ6xxWsljlgBA/i6yz7+dmE6dyszU9qkR7f2xDUQdg="),
        .init(secret1: "b69f38d981ad22b1fd25473756b2dd9c69d1554c6d31ae2a64c0fc82aafd86ac", secret2: "c916f18fd08a90c1d20bdfe27f31c53d33ebefdbe28e3da8797632b4b474b9df", nonce: "8b3c3f3aaf575328259ac5e3c08191dde308c573e3f4e7cda7042f82133143fb", kind: 1, scopeHex: "e381afe4b896e7958c", prk: "93c97bd637c3fc60d9dbdb410df34c4a614c52db57ed0f2a218e8a973e125265", encryptionKey: "e0a45a9306cc404aea91687e2b3c26abe23b0e12945799279e332c1880cacd78", macKey: "b21748a15b40d53bbdaeb81c419c160994780d141324fcb1ac65bcd8be6bb6f4", plaintextHex: "6e6f7374722e6c616e64206e697034347633", ciphertextB64: "A4s8PzqvV1MoJZrF48CBkd3jCMVz4/TnzacEL4ITMUP7b2QxXAKNEKp93ebvTrmrJ4aeJtLvqRokEeGXPBLE9UsAAAABAAAACeOBr+S4lueVjO04T51hx+sZw9n3gheEAyVOP0w/pWFvFtCuolpBkHvk"),
        .init(secret1: "20d7e7e95a8e6376438182425c33c9445055fa4a8bd2c57e5c7902015433e18d", secret2: "d38139efe4118dd5862c2556600ef7914d1659cabbd1a3d5fd9f2a0abe9dcbb3", nonce: "20c635f2f795178ea0bbf9856dd99da02138ba79337d2511d887f2a065b917c9", kind: 1, scopeHex: "efbbbfefbfbe", prk: "4f9c75fe7c850a79f83000901ef8f020301c06e413a84de01784971ec249bb7b", encryptionKey: "4345c818ddb2793427d8f5bb056e663cd941f910165601ff6806866cb7fb0fc3", macKey: "4eb9ee0ea464574336446a8aae961f05b6a65cd5feb2087417eabf5344c554da", plaintextHex: "f09f9088f09fa694", ciphertextB64: "AyDGNfL3lReOoLv5hW3ZnaAhOLp5M30lEdiH8qBluRfJTmsWPfIzALsx5OokjdKYAWkgDkES88FoC4k6wtgxUK8AAAABAAAABu+7v++/vmSE/qHW8+XDY97+8EQCRVPzORPYKrnLM6mNRp+zl2C6"),
        .init(secret1: "1a2c6e81b5f1038fdda1f555d0431d1bd3efb22d57f608708fa46d7d7b96f1f5", secret2: "c18596eac499c94e04334021c1b6952757d83aeda2aa84f90ab47357cdd29fdb", nonce: "a05a11dcd50aa1e855b7e11a816158a1a4827d21a00b60105ed3c8e802770d77", kind: 1, scopeHex: "ef8080", prk: "c043b08590fcc2ef03e299633af842deffd1b5dbd2bf598606bf02abb898303d", encryptionKey: "ba927e27a656a34369920ce7be028b6f6cb5878890123d1d3ba6b9f7ef4ab9c4", macKey: "71163bde93ea8fa3b5574e81869416bcb8f6954a3b746e1b2ed24546949e208c", plaintextHex: "e69a97e58fb7e58c96e381aee3819fe38281e381aee382a2e382afe382bbe382b9e588b6e5bea1e6a99fe883bde3818ce799bbe5a0b4e38197e381bee38197e3819fefbc81", ciphertextB64: "A6BaEdzVCqHoVbfhGoFhWKGkgn0hoAtgEF7TyOgCdw13O273WC9FSDyMtfOYNFvOlZQcaSrLdo6WBQ7ZI2UWn5MAAAABAAAAA++AgPPJWHFZya+M6arLz4wrWMHfL4Wyv4gYZBkicAvVBX0dMsr5tBcTP5xaM4lJZZnokEvMZRzYbjrfNTjT2gCWBapNdr/QrHxlTDa54nRmVR/2GBLkmQ5QeIiDm6OhfjXyYA=="),
    ]

    // MARK: - decrypt_only vectors (5, non-standard padding)

    private static let decryptOnlyVectors: [DecryptOnlyVector] = [
        .init(nonce: "d55b86093a16aabd228b9ac1724749e492fc3a81491c7374bd7a1d28a7b3b4a3", kind: 1, scopeHex: "", encryptionKey: "cbb7467f7c3a6f04c5ac6e4554de2034b67f2ac32a94d58f44e7a14e80912b0b", macKey: "784feeb31cf134baaa13d387f5102cf1f06a0e4d60cc737ba4c0311987401e9e", plaintextHex: "efbbbf48656c6c6f20776f726c6421", ciphertextB64: "A9Vbhgk6Fqq9IouawXJHSeSS/DqBSRxzdL16HSins7Sji9VE1vdW4PQiqseqUsGZsaAvIe2yGmfWOXiimOZHRUUAAAABAAAAAHm5SMpSTmibFgS1CqDSU5sC6MEPKNyTHS7oxNAb/AAFwta2Xpcc", note: "non-standard padding (23 bytes instead of 17)"),
        .init(nonce: "382baacbba8cba0cc6e8a7b4444fb157186118a18b3dbf652fb6b1e8267bcac1", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", encryptionKey: "c8ef9801a429de8526739c8d84c62eaf632b0d52023590c7449c8178885dcd57", macKey: "7ad04de35b988b240f78285e597fdca8e963988664f4808878afc2ba0aa9a4c1", plaintextHex: "6e6f7374722e6c616e64206e697034347633", ciphertextB64: "Azgrqsu6jLoMxuintERPsVcYYRihiz2/ZS+2segme8rBD0AqKypuSHff1x0FW+qO4lQlLltEjPWrvoMo7fbKOfwAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYznEO1UCJd2Ld0YV51u6kOkY3g22UhvNBAXY3sFnKmPu6fYx9s0rDWwNZcGxsMs+VydrONvM5F", note: "non-standard padding (36 bytes instead of 14)"),
        .init(nonce: "f08ea755450d9666cc122f2aa89794b170b8c69c6d7ff5f1d25bfae52164ca3a", kind: 1, scopeHex: "e381afe4b896e7958c", encryptionKey: "9110aa1049b70cdd93c38fa4888459d7286a78f5ca584d4dd658905660d4faea", macKey: "a597dea28fc706883f9dcc4917209ffc10788c95e86f090a694ea51bc5fe7a11", plaintextHex: "f09f9088f09fa694", ciphertextB64: "A/COp1VFDZZmzBIvKqiXlLFwuMacbX/18dJb+uUhZMo6uAhk3+WwQOcgQUgH4zhxaRzi80m70t5a9uV5B11EdpcAAAABAAAACeOBr+S4lueVjPeRbg5pf83dLf79+g1wPXb8mjm/rT9e", note: "non-standard padding (15 bytes instead of 24)"),
        .init(nonce: "f7e0f4b83ebb87657001b8e47d5940a3d062dfebae66da5a2ad0f4e498fedf85", kind: 1, scopeHex: "efbbbfefbfbe", encryptionKey: "94cf5b47ccfd36dadee996e637ae2a11bd9ac53ff7a29573fe368adf8b1e4f20", macKey: "a2e6d59755d7193c5cb9eba5965a42d2696062d455c2c7c535ad88b1c13d415b", plaintextHex: "e69a97e58fb7e58c96e381aee3819fe38281e381aee382a2e382afe382bbe382b9e588b6e5bea1e6a99fe883bde3818ce799bbe5a0b4e38197e381bee38197e3819fefbc81", ciphertextB64: "A/fg9Lg+u4dlcAG45H1ZQKPQYt/rrmbaWirQ9OSY/t+Fhm1xiEi20bWbMLIDrNw7Gz6XU0bDmmmgYl3g4z68Z+4AAAABAAAABu+7v++/vhLMBXKVPi51crCqEwCQnuB0V13+nE22PpVe7jQiELzDMqdrE6intBrXyHJLrJ4VteEZoiU92jZDoG9ieltDh0NnKRKq7cuW/om3DIhB0DCb0Pq6C5g/VaFaz2+mVPXV0p2BMW2MpuKUJ7/VYAlJPNSlK/JSYpQq", note: "non-standard padding (50 bytes instead of 27)"),
        .init(nonce: "a82a808ca1a40368336f19e9d3f83bfaaa35e4b8bffc9b5d9426ae518b9f34d1", kind: 1, scopeHex: "ef8080", encryptionKey: "cbecc983553fb82f9f3f615dd959a451d66388d8632d2028a684c9f02c611f3f", macKey: "5ed551ef02ba987cfdd4716c4a840a654501ea57aee9da055651669f85ac016e", plaintextHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", ciphertextB64: "A6gqgIyhpANoM28Z6dP4O/qqNeS4v/ybXZQmrlGLnzTRH0t5gnTV0ylQcxxkbLRHyKXnIagqYk5XMlG/85NYwuwAAAABAAAAA++AgM9zXmWWTYSixZDotwM+8HmJHW3aBt44KvZkhInVvt+Xmzh1YaPW8cbVr9kOQ38+cc5E285UfL164P71915Pr6mHNGOHtpKcX3P6TXCrch2MLux4m9xHf0BPcuv4+bwC0fLpNKVJLnNAnnGm7VOXdE2HhX4NP8ujzvH6cKTGfiyK0OlVpWX6Le+v/h2wm6m2SAHSJLbi6fIdA6MDilizVMqyaEFZ3n8eRYQ+To6eFKojRQw=", note: "non-standard padding (50 bytes instead of 64)"),
    ]

    // MARK: - long_encrypt_decrypt vectors (18)

    private static let longVectors: [LongVector] = [
        .init(secret1: "e35f016acdf0bec26f9f0e97fd813aa042727cb1e5ac2adf1c7b8d18d393f455", secret2: "e3c47278057365a1007414224f54ee99e6198ac6b6a82917e635375a1f9afa8e", nonce: "0598a9aa024df86e1e532e8cd3ed412e5b8bc914ff0340aa8868f9fd2fe2871f", kind: 1, scopeHex: "ef8080", patternHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", repeatCount: 511, expectedCiphertextSha256: "cf2c183f974c2601c0ec5d4fad0f0f98f18b0c83bc4e988c53ec1e496528deb1"),
        .init(secret1: "69efe21ce6ffe00d4126a019542e61324ff59fef06c81798cf1ec9810bfa5566", secret2: "91749344a212c2168587ad46197ef2eb026e3fa6839cb4286599c4f24820431c", nonce: "8c9f02398c9c5c11260b9ec27292bd32f0127c3e5366b255e0878ecb82e81eeb", kind: 1, scopeHex: "efbbbfefbfbe", patternHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", repeatCount: 1023, expectedCiphertextSha256: "8538f11d334dee64c561961ab7b371a90cb5ded3d1bf6c544d93aa4c72e5b1c0"),
        .init(secret1: "9ed97778c4bcaf3b5c66c41d3b97ec62e89e2bb9ead5d27a980a1c268a24a2c9", secret2: "58cba97d2985b001a7367a088a2e868a85158bd218f2a5858eb23a43de4ea382", nonce: "d8212d54ca0a36a7a5ed9f33656aebcd995f64dc6c4551a54b0dad5b897e254c", kind: 1, scopeHex: "e381afe4b896e7958c", patternHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", repeatCount: 2047, expectedCiphertextSha256: "66c5b453cc7123d9826115d437902db5226dd25f41aea9519f986938709c2901"),
        .init(secret1: "77930acaf9d28607482f0d329d65eea04fd218a957f25004d6606414dcdea848", secret2: "c31571de3b9b8053d5477a8dd090d7ed7ffbed98f8e9c904b8034ba77f74e232", nonce: "b40a2f2ae51c8355ed8bce7f810628c5fd3a4c5d4fe9170c159b9c7e9d1d5f87", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", patternHex: "f09fa694", repeatCount: 16383, expectedCiphertextSha256: "ccd2942a398aaab22845d6d65599a82fa9ee5fc1caecb5a8cc358771b1b7ba7b"),
        .init(secret1: "dc0ded78a0d133195b49429aadc6d424fde9b98a0e9ee12b4382bc0f08125a1c", secret2: "fac11ede5498f415f3a48cdf052a4e0d2f77fc4012baaf77de70a3f2cb4bc195", nonce: "7f2506e82ad6d97fa2cbbc2cf9f3a02bb61ce65bbe72a891c07c7bde23ade06b", kind: 1, scopeHex: "", patternHex: "f09fa694", repeatCount: 32767, expectedCiphertextSha256: "d84d643bda0d6f11dfc165eff69ab7c12c31f7f651603fe9e3397fb2ebb44a24"),
        .init(secret1: "b585991901f19ca1353b4122a591c3ade793338174f70326ee351d54b2b4c9be", secret2: "cdbc4210a142109928087965a6e47922ed65763165cebdb54498770da448d5b0", nonce: "aef913a704ce90355a134dd5f4ea253115d9d426269f371f45a33de3c79a90d7", kind: 1, scopeHex: "ef8080", patternHex: "f09fa694", repeatCount: 65535, expectedCiphertextSha256: "75d4386e1e5bf39c2775486c066274fbceb9e0aff2880b513ec1593ce8a68f74"),
        .init(secret1: "57420cd8c43b789a506e7dd1eb433b010e5323eb219de7c6a6a6f6976aa80693", secret2: "370091dce8dce4c3cf6b1a67ec8f41f9ae78a69ea902c67bdfe8930d90b2b7d6", nonce: "15ecf921c0e227f5199523de99193626087d506d998b8abd3c086e66fb25af0e", kind: 1, scopeHex: "efbbbfefbfbe", patternHex: "e38193e38293e381abe381a1e381afe4b896e7958c", repeatCount: 3120, expectedCiphertextSha256: "0577e05453f458e700740be3d849096f3d9d46924333ce3aa27c342a786a6cc4"),
        .init(secret1: "aeda4666950455c2e038d6b7d9e000be92be6aaecbb57b7f0f980ba29da52453", secret2: "9d819437f4eb60290bfb9aa547d426516a3ea07a2149e46f3310acc85dd45a18", nonce: "56146d9c3caf5c118288754d2caabd142eb45e1f2d80f3caf5183888ca2ee416", kind: 1, scopeHex: "e381afe4b896e7958c", patternHex: "e38193e38293e381abe381a1e381afe4b896e7958c", repeatCount: 6241, expectedCiphertextSha256: "6a0c112e126aa897f80ac73227fbb062ac7ded96f641a05fa4634a9f4a8c702b"),
        .init(secret1: "f153b2eadf9aa51bedf90ac8804dbe2bc4fed1ddd3861a857ae80a20d5c55f27", secret2: "22c42e7079ae57313d99c2f025c1be2f5dd999a3898d9aecbed7a207a1018510", nonce: "a7db4437442ca0ffbd836822c622115bc001de197c9f1a1d3d67a1e63c044d30", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", patternHex: "e38193e38293e381abe381a1e381afe4b896e7958c", repeatCount: 12482, expectedCiphertextSha256: "c066419c9ee88e7c8a77dbe25fac1dd8e9720fa4f481924058189062b12e3fe1"),
        .init(secret1: "217d14ae21140584417aa9bbcab4bdf4adccb5e74b191d65d2b357794f7f7143", secret2: "cccdef797a083bea633fcff31f255b57b5d5c99b682eda8ff132066dc3cd9127", nonce: "143cb408e61cf7b4281b0ccf300284a68d7df282f71667df5740b5f282424880", kind: 1, scopeHex: "", patternHex: "21", repeatCount: 65532, expectedCiphertextSha256: "e5360cffeef8c31c88a3455b920d9d9a98c8669b77d38ac232e0f67420467e5d"),
        .init(secret1: "625bbf8de97b71e8d70092bb6c576ee95895b7e6d2acf924790c80dd69785e8f", secret2: "13e7e6925ef02a644ea1c7bf8b68ff7de8c676ecf7f22d49a78a1802a6933189", nonce: "1bbbfd8803eac5c844e96ade2fdacf18fe3bda62312bdda102a29b52dd0c97bf", kind: 1, scopeHex: "ef8080", patternHex: "21", repeatCount: 131068, expectedCiphertextSha256: "8dd9a3157906d3a4e3de2b4d552cddae489a0996812bacca7728996a2605cae9"),
        .init(secret1: "266503c3818aa70800280c53be6f7f8156273c6c606cfbb0803d8eb63dca65f9", secret2: "9846126fad398ea9b6fe7ebddd7e28c021691eaff5355847cca42a2caacacb68", nonce: "9815cf89d4ab86023b1a427166fd8db49681a077d5724d1b743a57cd6fb96b81", kind: 1, scopeHex: "efbbbfefbfbe", patternHex: "21", repeatCount: 262140, expectedCiphertextSha256: "0bd33e75b6bb9be42a1fce897801d064943945a930977551437031a413e07443"),
        .init(secret1: "39506d419c1dede09cba910247457d66be7b213adbd981e3af0ef69b46c790f5", secret2: "5294e3ad19298a304753a32a42be2d44f3438f553677f30aab591f8a19ba4fd4", nonce: "8ccdf24876123afdbce42e59d4e03c53589150b4f23b087d3e3bfe89d96a54a6", kind: 1, scopeHex: "e381afe4b896e7958c", patternHex: "00", repeatCount: 65532, expectedCiphertextSha256: "c4c030de28d8b5fa9aafb1961aab296f078aced2988897c7907fa67cae073de1"),
        .init(secret1: "86bbd84e3e9e2db2e7ec37fb16900723aac499f1074b66586b44a3ed63022a3e", secret2: "17d3ff292c4a65e6181ecc201b9c5ed0c7e8408f36183659181414ddbb17c3d5", nonce: "f7ce68c00fb546c23efb88f778819c131797705abfc222886406b8547a9c244c", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", patternHex: "00", repeatCount: 131068, expectedCiphertextSha256: "3992c52ad7811ba181f572d37a0e1c9a4dbc1d9b127caa171896eb861d1e818c"),
        .init(secret1: "d38c5d7c0ba3b3e103318eb12952a481a204ab8dfd1d440b8882e9f0649ac0ee", secret2: "484475e3653226fd962fb9ca9ea8c8d4929473308eb53fd73a8ccd95e5eb8b98", nonce: "47fd0420348c7c4dead0c52874f2efe9ba9ecc9c4f9ee82319e1f33338d3ab86", kind: 1, scopeHex: "", patternHex: "00", repeatCount: 262140, expectedCiphertextSha256: "e03e2f16a5ee7e874d3cdc52e36ae8e73791d664540cdb7ac36f65687c7fc2a5"),
        .init(secret1: "fd20231a23032bde7acc638eb7086784670dcf8bc90e57a65c1d03d68594d3f0", secret2: "b47f3ba965fbea51c927b6846543480aeb25275c0e01c5c4d286ea087e70ee92", nonce: "6c9820a69d021d86a695eb3d5cc11ec638a799aca10ecfb9819b1efa3b9731ff", kind: 1, scopeHex: "ef8080", patternHex: "ff", repeatCount: 65532, expectedCiphertextSha256: "6621fc89a79464d19cbef605d962c9f43af90568c8c352007829445d1886c9bf"),
        .init(secret1: "38c961d0c8289789cec189e8db140f740abf34c8251eb16ad93cc5f9021abeb3", secret2: "e985cda5e08979c17a2c148532434c6f830bc2243e7a5592704972328f24d62d", nonce: "3957e9cc3be20433aff61993558572099e186312e714050cd3a589ff675f0e07", kind: 1, scopeHex: "efbbbfefbfbe", patternHex: "ff", repeatCount: 131068, expectedCiphertextSha256: "e41d7c737462f18b653683796d739c3b93f284c9bc15182bd94d278d13b84dea"),
        .init(secret1: "0666935a88d5196746c799ce0593dede7a8e8044930e62e07793950b9dab9b4d", secret2: "e3505f4e3b8fd37da2a9b4f3cb67864819e6272cdcdcf198f422598fa1114d21", nonce: "56fef50b564913b040a9ee83c9c1eb36ac6553a9e5ad699ac036fb4338a38e35", kind: 1, scopeHex: "e381afe4b896e7958c", patternHex: "ff", repeatCount: 262140, expectedCiphertextSha256: "086aaa494e3a4ca5bc573d91fbed292d9abe05fb730c54660bf5813250744aab"),
    ]

    // MARK: - invalid_decryption vectors (encryption-layer subset, 8)

    /// Subset of the 19 `invalid_decryption` vectors that the Encryption
    /// layer is responsible for rejecting:
    ///   - indices 0, 1: tampered MAC
    ///   - indices 2, 3: tampered padding (the all-zeros check)
    ///   - indices 14, 15: caller-supplied kind mismatch (MAC fails)
    ///   - indices 16, 17: caller-supplied scope mismatch (MAC fails)
    ///
    /// Skipped (ciphertext-layer / Context-layer chips will own these):
    ///   - 4–7: version-byte rejection (wire-frame)
    ///   - 8–11: payload-size/framing rejection (wire-frame)
    ///   - 12, 13: base64 parse rejection (wire-frame)
    ///   - 18: UTF-8 invalid scope (Context layer)
    private static let invalidDecryptionVectors: [InvalidDecryptionVector] = [
        .init(secret: "b2a4cca9347992d235fe115382098e313f6eaa3680248443b90c64e4e2ab039e", publicKey: "dc62907f84a35acecfc55b6d82961399f019981be0cd7d5e6a5a0620f9158870", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "Awx1nilOH4b0PT+ZszAS4TqOfADUQxWfAHAUVyJmy7c8EvrgFmKouWAVFZyjYN2XuuGSWHlKeuo9bF9t7MwMGfwAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzVeOxtyTClFO2/OPL6lpuSi3WFTdQgbhX6g/f1Iv2K6o=", why: "invalid MAC"),
        .init(secret: "83ed5a7ae0494831e938a0a8226472954be9daffb4bf5d7641473b35e959cf90", publicKey: "90ecf0dd8a793c74809735cc37cc3b9de20ffc9aae0eae7a1a0c740ecf09e395", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "A90ZzLN2HaQRTrzzLoobOtW+c9GyPxVp64fhIygpEpLaYYbCN6Pq1rjptBbN5S2vCFPCsE3wmU5u3Wx6L8oZxJoAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYz8Sxek35q19YWqmhyQNRHVZ+sNTtdgXO3MCnvjw0nanb233a39sc969Lm5DaUPN+yTKV0NbtYYN5hIWDOMOXj63XtzT7S7i/LAhv/l8y1zLTc0aUUoIjEg0EHi/FvlakK", why: "invalid MAC"),
        .init(secret: "efd2ac18f500ac0fa1b9639149432ff2d309d1b49c7f683c9ca4613d14449dce", publicKey: "84194beab56b44c426b866261772bc0a447ea34f94f2317ce1350cb714021a25", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "A5vkMZfJPQuWeOQsEiuZX1M4VJLY/k2G1mL8EKHK/yq7gifeC4V4zQ4L1iiQ1oVgmTmhwb/vd21Fm3YZrpYGEvYAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzQlapufh4trECMJjdb8m/TNFFcFJJSmiM/XQpnKXM/wc=", why: "invalid padding"),
        .init(secret: "2926c352495ce986639ccbb263ad2221df731bae6ee8ec329cbb5d00c5b9ca87", publicKey: "3c4b835fc7de0dd3a02971b559ccd5d3bcd2eb3cce7c1023b93892918effb71d", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "AzW5Wy/bvTYdcVOLIL8W26mfgTFG19S0H2BC9kyqgqK+TZ8oI00WJTNqwJIg8JE7DqDnOY+Q40Yd3G8Hi4GobQ8AAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYz3cI/rKzcQ22idVIBuFgLEVJaK1W5uxh6M6AdMoKKtdxO+lESYYWCEh/zzj35MFMwSJTn8z+XFvv9f2jYgQXHvPmY13wLOpIrpoS2W8luUbOVf9fip5mZXHw3neYvc7jA", why: "invalid padding"),
        .init(secret: "d4db7f6dcf6a45843739a806876a9da849f75f7a36702e7b4f7a10a986bf76cd", publicKey: "0377961328c3bb0db459cd22033d7a7ca1e29d7f42fd3f1b038530a2402879c8", kind: 1, scopeHex: "", ciphertextB64: "Ay1pBSibePLV49S4vfkgB4GCHR0Xywd7acm1WoC1ZaX6Jg38sM0PQAshZtniNKpUjQWZGw4e7kSKEgFIGhT6SxQAAAADAAAAABuabdmj5F6vlFssb3CHu/ndTMpdcPSWXklapkGwxJRS", why: "context mismatch (kind)"),
        .init(secret: "b00e9f068deb4b69c474109502839c981bd429075eeab9e5f41db9022c0cd869", publicKey: "6de2d6a91eb75f5e6038d633da8695f35fad807d5bad6b9e25ae8f526e10c05f", kind: 1, scopeHex: "68656c6c6f20776f726c6421", ciphertextB64: "A49dkIXX4dVAn6A9ql4cQ3MQfoU7rPrsg9/8V8d5NL9+A7Ntb9VIbBQ4V2ORFXS5rzOkHhZkKmtnn3dpMUiQWwsAACcQAAAADGhlbGxvIHdvcmxkIRb3rRdfIPuJvtEnjn6dj7RgKg1OUvGmCQoXmp+32EN6XL+vEHnbIbvLWLqIV7eCAmOqrPVGngCJEppHzzFMuhM=", why: "context mismatch (kind)"),
        .init(secret: "e150f3f5fd2eb47c49e8c1ee0ca51d3502d370108a98519d212731746fc513c2", publicKey: "901f54e63d0d1df5bf120e12faf00d6e4ec3c6d9fe81e0dc0f35cf1d5a489ac2", kind: 30078, scopeHex: "6170706c69636174696f6e2d64617461", ciphertextB64: "A/JaJhlnuKYJhr6LdZ46lkK7cw0nxGvA4rp112e70q0O9jMnXxaWqqNE7nZnllwl7yuGWRtcLU2q6uWAUZ6wthIAAHV+AAAAD2luY29ycmVjdC1zY29wZZ++z1BEvaKntWN9G+9EIT0da0luVAV/hAvOoUg90pXE4C6nsAKmpZ3Q2YfAvtUDlkMpxPv4u10Rlz0VGlPo9GtcGJp4X2aq/5gdbTZJF8mxnkhZ4zQqwRibV0JJ0ZNZxg==", why: "context mismatch (scope)"),
        .init(secret: "1c9c9ff5df8a9ff99e50b3dac27d987422567e9122075097edea2915e12580ca", publicKey: "32178882654a70441f1c507902ae3a89888ecd2266930a45f8d6b2f578643307", kind: 4, scopeHex: "efbbbf", ciphertextB64: "A3c7VODzMr9mQXQNRtw3MQsntesGokh3g8nQwdAK4iWqL/nV6HPOhnz5xFf1UjyvTrHJC8BrGjRefguMrJLrfy8AAAAEAAAAD2luY29ycmVjdC1zY29wZfvq9zBo8LQrHyulrPg0swuPZs4W3Xy1TSQlmczZ643aOllm+9DveIcqoXoQaGQTs1RDLeekOMNquv9a5XMWZ431ysJ44L3ET4Ztw5Eevnxx3pgaob8bCikyuGT+5CyR2A==", why: "context mismatch (scope)"),
    ]

    // MARK: - encrypt_decrypt: encrypt direction

    /// For each `encrypt_decrypt` vector, encrypt the JSON plaintext with the
    /// JSON-supplied keys + nonce + context, then assert the produced
    /// `(chacha20Ciphertext, mac)` matches the same fields parsed from the
    /// expected wire ciphertext.
    func testEncryptProducesSpecCiphertextAndMac() throws {
        var failures: [String] = []
        for (i, vec) in Self.encryptDecryptVectors.enumerated() {
            do {
                let plaintext = try hex(vec.plaintextHex)
                let encKey    = try hex(vec.encryptionKey)
                let macKey    = try hex(vec.macKey)
                let nonce     = try hex(vec.nonce)
                let scope     = try hex(vec.scopeHex)

                let (chacha, mac) = try NIP44v3.Encryption.encrypt(
                    plaintext: plaintext,
                    encryptionKey: encKey,
                    macKey: macKey,
                    kind: vec.kind,
                    scope: scope,
                    nonce: nonce
                )

                let expectedWire = try Self.decodeBase64(vec.ciphertextB64)
                let parsed = try Self.parseWire(expectedWire)
                if chacha != parsed.chacha20Ct {
                    failures.append("vec[\(i)] chacha mismatch: got \(chacha.hex.prefix(40))..., want \(parsed.chacha20Ct.hex.prefix(40))...")
                }
                if mac != parsed.mac {
                    failures.append("vec[\(i)] mac mismatch: got \(mac.hex), want \(parsed.mac.hex)")
                }
            } catch {
                failures.append("vec[\(i)] threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) encrypt failures:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - encrypt_decrypt: decrypt direction

    func testDecryptRecoversSpecPlaintext() throws {
        var failures: [String] = []
        for (i, vec) in Self.encryptDecryptVectors.enumerated() {
            do {
                let wire      = try Self.decodeBase64(vec.ciphertextB64)
                let parsed    = try Self.parseWire(wire)
                let encKey    = try hex(vec.encryptionKey)
                let macKey    = try hex(vec.macKey)
                let scope     = try hex(vec.scopeHex)

                let plaintext = try NIP44v3.Encryption.decrypt(
                    chacha20Ciphertext: parsed.chacha20Ct,
                    mac: parsed.mac,
                    encryptionKey: encKey,
                    macKey: macKey,
                    kind: vec.kind,
                    scope: scope,
                    nonce: parsed.nonce
                )

                let expected = try hex(vec.plaintextHex)
                if plaintext != expected {
                    failures.append("vec[\(i)] plaintext mismatch: got \(plaintext.hex), want \(expected.hex)")
                }
            } catch {
                failures.append("vec[\(i)] threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) decrypt failures:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - decrypt_only: non-standard padding (Amber gotcha)

    /// 🔥 The 5 `decrypt_only` vectors all have padding longer or shorter than
    /// `Padding.targetSize(plaintext_len)`. Implementations that recompute
    /// the expected padded length and compare reject these — Amber's PR #448
    /// did this and broke nostrconnect interop. Our decrypt MUST succeed.
    func testDecryptAcceptsNonStandardPaddingLengths() throws {
        var failures: [String] = []
        for (i, vec) in Self.decryptOnlyVectors.enumerated() {
            do {
                let wire   = try Self.decodeBase64(vec.ciphertextB64)
                let parsed = try Self.parseWire(wire)
                let encKey = try hex(vec.encryptionKey)
                let macKey = try hex(vec.macKey)
                let scope  = try hex(vec.scopeHex)

                let plaintext = try NIP44v3.Encryption.decrypt(
                    chacha20Ciphertext: parsed.chacha20Ct,
                    mac: parsed.mac,
                    encryptionKey: encKey,
                    macKey: macKey,
                    kind: vec.kind,
                    scope: scope,
                    nonce: parsed.nonce
                )

                let expected = try hex(vec.plaintextHex)
                if plaintext != expected {
                    failures.append("vec[\(i)] (\(vec.note)) plaintext mismatch: got \(plaintext.hex), want \(expected.hex)")
                }
            } catch {
                failures.append("vec[\(i)] (\(vec.note)) threw \(error) — this is the Amber gotcha")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) non-standard-padding decrypt failures:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - long_encrypt_decrypt: SHA-256 of full wire

    /// Each long vector is `pattern × repeat`. Build the plaintext, derive keys
    /// via the Keys layer, encrypt, assemble the wire (version || nonce || mac
    /// || u32_be(kind) || u32_be(scope_len) || scope || chacha20_ct), SHA-256.
    func testEncryptLongMessagesMatchCiphertextSha256() throws {
        var failures: [String] = []
        for (i, vec) in Self.longVectors.enumerated() {
            do {
                let secret1   = try hex(vec.secret1)
                let secret2   = try hex(vec.secret2)
                let nonce     = try hex(vec.nonce)
                let scope     = try hex(vec.scopeHex)
                let pattern   = try hex(vec.patternHex)

                var plaintext = Data()
                plaintext.reserveCapacity(pattern.count * vec.repeatCount)
                for _ in 0..<vec.repeatCount { plaintext.append(pattern) }

                let pubkey2   = try Self.xOnlyPublicKey(forSecret: secret2)
                let keys      = try NIP44v3.Keys.derive(seckey: secret1, pubkey: pubkey2, nonce: nonce)

                let (chacha, mac) = try NIP44v3.Encryption.encrypt(
                    plaintext: plaintext,
                    encryptionKey: keys.encryptionKey,
                    macKey: keys.macKey,
                    kind: vec.kind,
                    scope: scope,
                    nonce: nonce
                )

                let wire = Self.assembleWire(version: 0x03, nonce: nonce, mac: mac, kind: vec.kind, scope: scope, chacha20Ct: chacha)
                // ncrypt-go's `ciphertext_sha256` is computed over the BASE64
                // wire bytes (ASCII string), not raw wire — its `Encode()`
                // returns the base64 output bytes (`ciphertext.go` line 40).
                let wireB64 = Data(wire.base64EncodedString().utf8)
                let gotHex  = Data(SHA256.hash(data: wireB64)).hex
                if gotHex != vec.expectedCiphertextSha256 {
                    failures.append("vec[\(i)] sha256 mismatch: got \(gotHex), want \(vec.expectedCiphertextSha256)")
                }
            } catch {
                failures.append("vec[\(i)] threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) long-message failures:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - invalid_decryption: encryption-layer rejections

    /// Each of the 8 vectors here MUST be rejected by our decrypt. The
    /// caller-supplied kind+scope are taken from the JSON as-is (for the
    /// mismatch cases, these differ from the values bound into the wire
    /// MAC, so MAC verify fails). For tampered MAC/padding cases the
    /// context already matches but the wire bytes themselves are corrupt.
    func testDecryptRejectsInvalidVectors() throws {
        var failures: [String] = []
        for (i, vec) in Self.invalidDecryptionVectors.enumerated() {
            do {
                let wire     = try Self.decodeBase64(vec.ciphertextB64)
                let parsed   = try Self.parseWire(wire)
                let seckey   = try hex(vec.secret)
                let pubkey   = try hex(vec.publicKey)
                let scope    = try hex(vec.scopeHex)
                let keys     = try NIP44v3.Keys.derive(seckey: seckey, pubkey: pubkey, nonce: parsed.nonce)

                do {
                    _ = try NIP44v3.Encryption.decrypt(
                        chacha20Ciphertext: parsed.chacha20Ct,
                        mac: parsed.mac,
                        encryptionKey: keys.encryptionKey,
                        macKey: keys.macKey,
                        kind: vec.kind,
                        scope: scope,
                        nonce: parsed.nonce
                    )
                    failures.append("vec[\(i)] (\(vec.why)) UNEXPECTEDLY SUCCEEDED")
                } catch NIP44v3.Encryption.Error.macInvalid,
                        NIP44v3.Encryption.Error.paddingInvalid {
                    // expected
                } catch {
                    failures.append("vec[\(i)] (\(vec.why)) wrong error: \(error)")
                }
            } catch {
                failures.append("vec[\(i)] (\(vec.why)) setup threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) invalid-decryption failures:\n" + failures.prefix(10).joined(separator: "\n"))
    }

    // MARK: - Encryption-layer edge cases

    func testEncryptRejectsWrongLengthKeyMaterial() {
        let plaintext = Data("hi".utf8)
        let nonce  = Data(repeating: 0x01, count: 32)
        let okEnc  = Data(repeating: 0x02, count: 32)
        let okMac  = Data(repeating: 0x03, count: 32)

        XCTAssertThrowsError(try NIP44v3.Encryption.encrypt(plaintext: plaintext, encryptionKey: Data(count: 31), macKey: okMac, kind: 1, scope: Data(), nonce: nonce))
        XCTAssertThrowsError(try NIP44v3.Encryption.encrypt(plaintext: plaintext, encryptionKey: okEnc, macKey: Data(count: 31), kind: 1, scope: Data(), nonce: nonce))
        XCTAssertThrowsError(try NIP44v3.Encryption.encrypt(plaintext: plaintext, encryptionKey: okEnc, macKey: okMac, kind: 1, scope: Data(), nonce: Data(count: 31)))
    }

    // MARK: - Helpers

    private func hex(_ s: String) throws -> Data {
        guard let d = Data(hexString: s) else {
            throw NSError(domain: "NIP44v3EncryptionTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad hex: \(s.prefix(40))"])
        }
        return d
    }

    private static func decodeBase64(_ s: String) throws -> Data {
        guard let d = Data(base64Encoded: s) else {
            throw NSError(domain: "NIP44v3EncryptionTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "bad base64: \(s.prefix(40))"])
        }
        return d
    }

    private struct ParsedWire {
        let version: UInt8
        let nonce: Data
        let mac: Data
        let kind: UInt32
        let scope: Data
        let chacha20Ct: Data
    }

    /// Wire layout (Ciphertext layer, future):
    ///   version(1) || nonce(32) || mac(32) || u32_be(kind)(4) || u32_be(scope_len)(4) || scope(N) || chacha20_ct(rest)
    private static func parseWire(_ data: Data) throws -> ParsedWire {
        guard data.count >= 73 else {
            throw NSError(domain: "NIP44v3EncryptionTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "wire too short"])
        }
        let base = data.startIndex
        let version = data[base]
        let nonce = data[(base + 1)..<(base + 33)]
        let mac   = data[(base + 33)..<(base + 65)]
        let kind = readU32BE(data, offset: base + 65)
        let scopeLen = Int(readU32BE(data, offset: base + 69))
        let scopeStart = base + 73
        let scopeEnd   = scopeStart + scopeLen
        guard scopeEnd <= data.endIndex else {
            throw NSError(domain: "NIP44v3EncryptionTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "scope length out of bounds"])
        }
        let scope = data[scopeStart..<scopeEnd]
        let chacha = data[scopeEnd..<data.endIndex]
        return ParsedWire(version: version, nonce: Data(nonce), mac: Data(mac), kind: kind, scope: Data(scope), chacha20Ct: Data(chacha))
    }

    private static func assembleWire(version: UInt8, nonce: Data, mac: Data, kind: UInt32, scope: Data, chacha20Ct: Data) -> Data {
        var d = Data()
        d.reserveCapacity(1 + 32 + 32 + 4 + 4 + scope.count + chacha20Ct.count)
        d.append(version)
        d.append(nonce)
        d.append(mac)
        appendU32BE(&d, kind)
        appendU32BE(&d, UInt32(scope.count))
        d.append(scope)
        d.append(chacha20Ct)
        return d
    }

    private static func readU32BE(_ d: Data, offset: Data.Index) -> UInt32 {
        var v: UInt32 = 0
        v |= UInt32(d[offset]) << 24
        v |= UInt32(d[offset + 1]) << 16
        v |= UInt32(d[offset + 2]) << 8
        v |= UInt32(d[offset + 3])
        return v
    }

    private static func appendU32BE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8((v >> 24) & 0xff))
        d.append(UInt8((v >> 16) & 0xff))
        d.append(UInt8((v >> 8) & 0xff))
        d.append(UInt8(v & 0xff))
    }

    /// BIP-340 x-only public key (32 bytes) from a 32-byte secret. Same shape
    /// as the Keys-layer tests use.
    private static func xOnlyPublicKey(forSecret seckey: Data) throws -> Data {
        let priv = try P256K.Schnorr.PrivateKey(dataRepresentation: seckey)
        return Data(priv.xonly.bytes)
    }
}
