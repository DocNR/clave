import XCTest
import CryptoKit
import P256K
@testable import Clave

/// End-to-end tests for the NIP-44 v3 top-level public API + Context.
///
/// Validates `NIP44v3.encrypt(...)` / `.decrypt(...)` / `.Context(...)`
/// against the spec test-vectors.json at commit `5680754` (2026-06-02).
/// The per-layer test files (`NIP44v3PaddingTests`, `NIP44v3KeysTests`,
/// `NIP44v3EncryptionTests`, `NIP44v3CiphertextTests`) cover each layer
/// in isolation; this file exercises them composed through the public
/// API entries the eventual NIP-46 dispatch in `LightSigner.swift` will
/// call.
///
/// Categories exercised:
///   1. `encrypt_decrypt` × 10 — byte-equal wire (with injected nonce
///      via `_testOnly_encrypt`) + decrypt from both perspectives.
///   2. `long_encrypt_decrypt` × 18 — SHA-256 of the wire matches the
///      vector + decrypt round-trip on large messages.
///   3. `decrypt_only` × 5 — non-standard padding tolerance flows
///      end-to-end through the public API (the Amber-PR-#448 gotcha
///      gated through all four composed layers).
///   4. `invalid_decryption` × 19 — each rejects with the correct
///      top-level `NIP44v3.Error` case (or, for vector 18,
///      `NIP44v3.Context.Error.scopeNotUTF8` at construction time).
///   5. Context UTF-8 validation — valid/invalid corpus + empty-scope
///      convenience init.
///   6. Random-nonce smoke — two consecutive encrypts produce distinct
///      wires that both decrypt correctly.
///   7. Edge cases — empty plaintext, wrong-length seckey/pubkey.
final class NIP44v3Tests: XCTestCase {

    // MARK: - Vector types

    private struct EncryptDecryptVector {
        let secret1, secret2, nonce: String
        let kind: UInt32
        let scopeHex: String
        let plaintextHex: String
        let ciphertextB64: String
    }

    private struct LongVector {
        let secret1, secret2, nonce: String
        let kind: UInt32
        let scopeHex: String
        let patternHex: String
        let repeatCount: Int
        let ciphertextSha256: String
    }

    private struct DecryptOnlyVector {
        let secret1, secret2, nonce: String
        let kind: UInt32
        let scopeHex: String
        let plaintextHex: String
        let ciphertextB64: String
        let note: String
    }

    private struct InvalidVector {
        let idx: Int
        let secret, publicKey: String
        let kind: UInt32
        let scopeHex: String
        let ciphertextB64: String
        let why: String
    }

    // MARK: - encrypt_decrypt (10)

    private static let encryptDecryptVectors: [EncryptDecryptVector] = [
        .init(secret1: "1b7023bb70248d8edab44658c5e2677dd7e5d7093ec062eb204975df4255fddc", secret2: "827844538be12d1cfa0f7fa096668cc4f2c4a25c2c8f7e92ca6cb05c3c445d17", nonce: "b5451a6d90ec575b4cdcedf4987429eeab1bbaa192ea3db89eafa058826885a6", kind: 1, scopeHex: "", plaintextHex: "efbbbf48656c6c6f20776f726c6421", ciphertextB64: "A7VFGm2Q7FdbTNzt9Jh0Ke6rG7qhkuo9uJ6voFiCaIWmMJrEDBNRRCorotVxmP7ge14Y+UtDn1/Pn3uzAaNNzHUAAAABAAAAAPJgoFXpn6mjFE0hUZrnZljeaYwSdqBKbVDXcyLgVGC8"),
        .init(secret1: "f9869a8237c9fffd3bc175d21cc144051de4889da28b462ca1e4557adc2d2275", secret2: "c4c53829b9ad83682873761b71d667457935eaa84159a206dea58f18be09d05d", nonce: "f99a4a4a84a4906d839b62861dcd54883cccabb3616d003f27250ac00e672c50", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", plaintextHex: "6e6f7374722e6c616e64206e697034347633", ciphertextB64: "A/maSkqEpJBtg5tihh3NVIg8zKuzYW0APyclCsAOZyxQfHiK7t6u8D4JR3dRUKMpBRQzoOYtunePezG3p65AXPEAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzvgOo5isSBI06S531Yb9j9l+LpL9dA0D9/LLtorb866Y="),
        .init(secret1: "2f69dcb9891cf749ab0b4e07a718a9e364c44e7603d851c7c09e080b631534fb", secret2: "110ffc1f2ea8b15ffd5d24c59dc1b72c4b1f8180dd5ccb6a68097ff328f49e54", nonce: "ffffd9144f5fe48077ac672e1366d303dfebdf60b1abd07fce1ff762bb25a4aa", kind: 1, scopeHex: "e381afe4b896e7958c", plaintextHex: "f09f9088f09fa694", ciphertextB64: "A///2RRPX+SAd6xnLhNm0wPf699gsavQf84f92K7JaSqrm0b+bxgKBqNS04QURAmEXZlYBY9Ed4neDw2uOAqkGcAAAABAAAACeOBr+S4lueVjIEUNKR4ekMqHUoWb/ks495G0c1lD6oPQ3ZFsa4LHvRE"),
        .init(secret1: "e945941c87478b88c8af150219ed8055692f3f01543a3dec3cb40854fdf8545b", secret2: "11eefd6b9a1a4d4e4b71840aa77eb47d3821d825ca8d4e45065ff563bdc342d9", nonce: "726cab7f363afe8c0783dc1d2d6e4700ace52a26996a53ba3928ef3c865cc235", kind: 1, scopeHex: "efbbbfefbfbe", plaintextHex: "e69a97e58fb7e58c96e381aee3819fe38281e381aee382a2e382afe382bbe382b9e588b6e5bea1e6a99fe883bde3818ce799bbe5a0b4e38197e381bee38197e3819fefbc81", ciphertextB64: "A3Jsq382Ov6MB4PcHS1uRwCs5SommWpTujko7zyGXMI1d8FRsRgcGnjOo+Ifry8x/QC+vDDkPCHv7WDaem7tQ10AAAABAAAABu+7v++/vm+/pDQcUXHli2Do1EEoqYFmF/67UUcl31Ks9TRy9vCwc2IUY6Ev9T+oBanqVWGbPgAWysjisi5dIPAEcndMK2Ur4m2UqTo3WVTIqKmy30ad5VOwl4v1AHweiZvJU/w+lQ=="),
        .init(secret1: "98c7c39a4abf5f923db71a3e2c0951fa020bc5ba1555c158ebc8663e1582bb01", secret2: "b775d4f4ef14b1a93cc34a534a64a1ec2cd1a64a5a7b45f837af5ea4595b37dc", nonce: "ec64f769d99bc3c6f5231145b546334275d910e11fe9a11351ee487e4dbfd4ec", kind: 1, scopeHex: "ef8080", plaintextHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", ciphertextB64: "A+xk92nZm8PG9SMRRbVGM0J12RDhH+mhE1HuSH5Nv9Tsg6J943ljpXnIaVIuHaXrWfa99RkqZOW6NGy6oqm2HocAAAABAAAAA++AgNCkiGZgN5Uzx1HVpcoLQQisIwWD32PqBoQ4T598/KmHsxUAGEARiXh9ikGXtwKuH8a8EzTcobkr4OEXfPs0h5u0A1HUJ3M/Hc/orcqZgeA0RhfZe3IASVmQfU9/pge+nTPjJVK5ZHOlEBnt7tmYcT8vqv9bpxbyhCBGMO6nEFhUtrr2IKCW3Z6vljg7T3FDr7aVIY/cxniq4E+e5ec9pZ+wn3j9PAibWgEANCDK5nyiH6B348lnqxfmu8bvzzyPhA=="),
        .init(secret1: "b0e73a57d65972a4276879cb8604f683dfd9197cc236f299ea55acb66bfa8ff0", secret2: "ebf87d9858227055ac9f789911edad1b55777edc99dd4b8634f52bb8c0922edc", nonce: "c027624d50656a34add75cec7e476e6287bc919cacf0ebbda6d3277c02b0a239", kind: 1, scopeHex: "", plaintextHex: "6120646563656e7472616c697a65642070726f746f636f6c20666f7220616e797468696e67", ciphertextB64: "A8AnYk1QZWo0rddc7H5HbmKHvJGcrPDrvabTJ3wCsKI5ZMf+aMW7P7Iz5qDghY+87TL5pZjNiykm0xpMKlkwITgAAAABAAAAAE2F94qgXOR+co8R41Vu04wLtkrI3Y5QJbVmutA5v1MkCgrLCmZAwNXhQsUnzUOuAPloXVQQdgQL4gmVgIz0rqQ="),
        .init(secret1: "0bac57d63af3e6650152577f7d5515062270b68cd2cda1250604ab70b7cdf091", secret2: "ddb09a891ef13bbf1b9ed8fb403afce4eea2197428da805dc85d90eee76e20f2", nonce: "0da18d3ebcc5f269f6415e3e3fcb5e1a8d76318fe439ec83cfdf99ef8eaacee9", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", plaintextHex: "efbbbf48656c6c6f20776f726c6421", ciphertextB64: "Aw2hjT68xfJp9kFePj/LXhqNdjGP5Dnsg8/fme+Oqs7p+xyexXUdk8ZJ2rtLWT1xQ9lXxWSiagEVpRg35PndmKQAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzuKZ6xxWsljlgBA/i6yz7+dmE6dyszU9qkR7f2xDUQdg="),
        .init(secret1: "b69f38d981ad22b1fd25473756b2dd9c69d1554c6d31ae2a64c0fc82aafd86ac", secret2: "c916f18fd08a90c1d20bdfe27f31c53d33ebefdbe28e3da8797632b4b474b9df", nonce: "8b3c3f3aaf575328259ac5e3c08191dde308c573e3f4e7cda7042f82133143fb", kind: 1, scopeHex: "e381afe4b896e7958c", plaintextHex: "6e6f7374722e6c616e64206e697034347633", ciphertextB64: "A4s8PzqvV1MoJZrF48CBkd3jCMVz4/TnzacEL4ITMUP7b2QxXAKNEKp93ebvTrmrJ4aeJtLvqRokEeGXPBLE9UsAAAABAAAACeOBr+S4lueVjO04T51hx+sZw9n3gheEAyVOP0w/pWFvFtCuolpBkHvk"),
        .init(secret1: "20d7e7e95a8e6376438182425c33c9445055fa4a8bd2c57e5c7902015433e18d", secret2: "d38139efe4118dd5862c2556600ef7914d1659cabbd1a3d5fd9f2a0abe9dcbb3", nonce: "20c635f2f795178ea0bbf9856dd99da02138ba79337d2511d887f2a065b917c9", kind: 1, scopeHex: "efbbbfefbfbe", plaintextHex: "f09f9088f09fa694", ciphertextB64: "AyDGNfL3lReOoLv5hW3ZnaAhOLp5M30lEdiH8qBluRfJTmsWPfIzALsx5OokjdKYAWkgDkES88FoC4k6wtgxUK8AAAABAAAABu+7v++/vmSE/qHW8+XDY97+8EQCRVPzORPYKrnLM6mNRp+zl2C6"),
        .init(secret1: "1a2c6e81b5f1038fdda1f555d0431d1bd3efb22d57f608708fa46d7d7b96f1f5", secret2: "c18596eac499c94e04334021c1b6952757d83aeda2aa84f90ab47357cdd29fdb", nonce: "a05a11dcd50aa1e855b7e11a816158a1a4827d21a00b60105ed3c8e802770d77", kind: 1, scopeHex: "ef8080", plaintextHex: "e69a97e58fb7e58c96e381aee3819fe38281e381aee382a2e382afe382bbe382b9e588b6e5bea1e6a99fe883bde3818ce799bbe5a0b4e38197e381bee38197e3819fefbc81", ciphertextB64: "A6BaEdzVCqHoVbfhGoFhWKGkgn0hoAtgEF7TyOgCdw13O273WC9FSDyMtfOYNFvOlZQcaSrLdo6WBQ7ZI2UWn5MAAAABAAAAA++AgPPJWHFZya+M6arLz4wrWMHfL4Wyv4gYZBkicAvVBX0dMsr5tBcTP5xaM4lJZZnokEvMZRzYbjrfNTjT2gCWBapNdr/QrHxlTDa54nRmVR/2GBLkmQ5QeIiDm6OhfjXyYA=="),
    ]

    // MARK: - long_encrypt_decrypt (18)

    private static let longVectors: [LongVector] = [
        .init(secret1: "e35f016acdf0bec26f9f0e97fd813aa042727cb1e5ac2adf1c7b8d18d393f455", secret2: "e3c47278057365a1007414224f54ee99e6198ac6b6a82917e635375a1f9afa8e", nonce: "0598a9aa024df86e1e532e8cd3ed412e5b8bc914ff0340aa8868f9fd2fe2871f", kind: 1, scopeHex: "ef8080", patternHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", repeatCount: 511, ciphertextSha256: "cf2c183f974c2601c0ec5d4fad0f0f98f18b0c83bc4e988c53ec1e496528deb1"),
        .init(secret1: "69efe21ce6ffe00d4126a019542e61324ff59fef06c81798cf1ec9810bfa5566", secret2: "91749344a212c2168587ad46197ef2eb026e3fa6839cb4286599c4f24820431c", nonce: "8c9f02398c9c5c11260b9ec27292bd32f0127c3e5366b255e0878ecb82e81eeb", kind: 1, scopeHex: "efbbbfefbfbe", patternHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", repeatCount: 1023, ciphertextSha256: "8538f11d334dee64c561961ab7b371a90cb5ded3d1bf6c544d93aa4c72e5b1c0"),
        .init(secret1: "9ed97778c4bcaf3b5c66c41d3b97ec62e89e2bb9ead5d27a980a1c268a24a2c9", secret2: "58cba97d2985b001a7367a088a2e868a85158bd218f2a5858eb23a43de4ea382", nonce: "d8212d54ca0a36a7a5ed9f33656aebcd995f64dc6c4551a54b0dad5b897e254c", kind: 1, scopeHex: "e381afe4b896e7958c", patternHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", repeatCount: 2047, ciphertextSha256: "66c5b453cc7123d9826115d437902db5226dd25f41aea9519f986938709c2901"),
        .init(secret1: "77930acaf9d28607482f0d329d65eea04fd218a957f25004d6606414dcdea848", secret2: "c31571de3b9b8053d5477a8dd090d7ed7ffbed98f8e9c904b8034ba77f74e232", nonce: "b40a2f2ae51c8355ed8bce7f810628c5fd3a4c5d4fe9170c159b9c7e9d1d5f87", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", patternHex: "f09fa694", repeatCount: 16383, ciphertextSha256: "ccd2942a398aaab22845d6d65599a82fa9ee5fc1caecb5a8cc358771b1b7ba7b"),
        .init(secret1: "dc0ded78a0d133195b49429aadc6d424fde9b98a0e9ee12b4382bc0f08125a1c", secret2: "fac11ede5498f415f3a48cdf052a4e0d2f77fc4012baaf77de70a3f2cb4bc195", nonce: "7f2506e82ad6d97fa2cbbc2cf9f3a02bb61ce65bbe72a891c07c7bde23ade06b", kind: 1, scopeHex: "", patternHex: "f09fa694", repeatCount: 32767, ciphertextSha256: "d84d643bda0d6f11dfc165eff69ab7c12c31f7f651603fe9e3397fb2ebb44a24"),
        .init(secret1: "b585991901f19ca1353b4122a591c3ade793338174f70326ee351d54b2b4c9be", secret2: "cdbc4210a142109928087965a6e47922ed65763165cebdb54498770da448d5b0", nonce: "aef913a704ce90355a134dd5f4ea253115d9d426269f371f45a33de3c79a90d7", kind: 1, scopeHex: "ef8080", patternHex: "f09fa694", repeatCount: 65535, ciphertextSha256: "75d4386e1e5bf39c2775486c066274fbceb9e0aff2880b513ec1593ce8a68f74"),
        .init(secret1: "57420cd8c43b789a506e7dd1eb433b010e5323eb219de7c6a6a6f6976aa80693", secret2: "370091dce8dce4c3cf6b1a67ec8f41f9ae78a69ea902c67bdfe8930d90b2b7d6", nonce: "15ecf921c0e227f5199523de99193626087d506d998b8abd3c086e66fb25af0e", kind: 1, scopeHex: "efbbbfefbfbe", patternHex: "e38193e38293e381abe381a1e381afe4b896e7958c", repeatCount: 3120, ciphertextSha256: "0577e05453f458e700740be3d849096f3d9d46924333ce3aa27c342a786a6cc4"),
        .init(secret1: "aeda4666950455c2e038d6b7d9e000be92be6aaecbb57b7f0f980ba29da52453", secret2: "9d819437f4eb60290bfb9aa547d426516a3ea07a2149e46f3310acc85dd45a18", nonce: "56146d9c3caf5c118288754d2caabd142eb45e1f2d80f3caf5183888ca2ee416", kind: 1, scopeHex: "e381afe4b896e7958c", patternHex: "e38193e38293e381abe381a1e381afe4b896e7958c", repeatCount: 6241, ciphertextSha256: "6a0c112e126aa897f80ac73227fbb062ac7ded96f641a05fa4634a9f4a8c702b"),
        .init(secret1: "f153b2eadf9aa51bedf90ac8804dbe2bc4fed1ddd3861a857ae80a20d5c55f27", secret2: "22c42e7079ae57313d99c2f025c1be2f5dd999a3898d9aecbed7a207a1018510", nonce: "a7db4437442ca0ffbd836822c622115bc001de197c9f1a1d3d67a1e63c044d30", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", patternHex: "e38193e38293e381abe381a1e381afe4b896e7958c", repeatCount: 12482, ciphertextSha256: "c066419c9ee88e7c8a77dbe25fac1dd8e9720fa4f481924058189062b12e3fe1"),
        .init(secret1: "217d14ae21140584417aa9bbcab4bdf4adccb5e74b191d65d2b357794f7f7143", secret2: "cccdef797a083bea633fcff31f255b57b5d5c99b682eda8ff132066dc3cd9127", nonce: "143cb408e61cf7b4281b0ccf300284a68d7df282f71667df5740b5f282424880", kind: 1, scopeHex: "", patternHex: "21", repeatCount: 65532, ciphertextSha256: "e5360cffeef8c31c88a3455b920d9d9a98c8669b77d38ac232e0f67420467e5d"),
        .init(secret1: "625bbf8de97b71e8d70092bb6c576ee95895b7e6d2acf924790c80dd69785e8f", secret2: "13e7e6925ef02a644ea1c7bf8b68ff7de8c676ecf7f22d49a78a1802a6933189", nonce: "1bbbfd8803eac5c844e96ade2fdacf18fe3bda62312bdda102a29b52dd0c97bf", kind: 1, scopeHex: "ef8080", patternHex: "21", repeatCount: 131068, ciphertextSha256: "8dd9a3157906d3a4e3de2b4d552cddae489a0996812bacca7728996a2605cae9"),
        .init(secret1: "266503c3818aa70800280c53be6f7f8156273c6c606cfbb0803d8eb63dca65f9", secret2: "9846126fad398ea9b6fe7ebddd7e28c021691eaff5355847cca42a2caacacb68", nonce: "9815cf89d4ab86023b1a427166fd8db49681a077d5724d1b743a57cd6fb96b81", kind: 1, scopeHex: "efbbbfefbfbe", patternHex: "21", repeatCount: 262140, ciphertextSha256: "0bd33e75b6bb9be42a1fce897801d064943945a930977551437031a413e07443"),
        .init(secret1: "39506d419c1dede09cba910247457d66be7b213adbd981e3af0ef69b46c790f5", secret2: "5294e3ad19298a304753a32a42be2d44f3438f553677f30aab591f8a19ba4fd4", nonce: "8ccdf24876123afdbce42e59d4e03c53589150b4f23b087d3e3bfe89d96a54a6", kind: 1, scopeHex: "e381afe4b896e7958c", patternHex: "00", repeatCount: 65532, ciphertextSha256: "c4c030de28d8b5fa9aafb1961aab296f078aced2988897c7907fa67cae073de1"),
        .init(secret1: "86bbd84e3e9e2db2e7ec37fb16900723aac499f1074b66586b44a3ed63022a3e", secret2: "17d3ff292c4a65e6181ecc201b9c5ed0c7e8408f36183659181414ddbb17c3d5", nonce: "f7ce68c00fb546c23efb88f778819c131797705abfc222886406b8547a9c244c", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", patternHex: "00", repeatCount: 131068, ciphertextSha256: "3992c52ad7811ba181f572d37a0e1c9a4dbc1d9b127caa171896eb861d1e818c"),
        .init(secret1: "d38c5d7c0ba3b3e103318eb12952a481a204ab8dfd1d440b8882e9f0649ac0ee", secret2: "484475e3653226fd962fb9ca9ea8c8d4929473308eb53fd73a8ccd95e5eb8b98", nonce: "47fd0420348c7c4dead0c52874f2efe9ba9ecc9c4f9ee82319e1f33338d3ab86", kind: 1, scopeHex: "", patternHex: "00", repeatCount: 262140, ciphertextSha256: "e03e2f16a5ee7e874d3cdc52e36ae8e73791d664540cdb7ac36f65687c7fc2a5"),
        .init(secret1: "fd20231a23032bde7acc638eb7086784670dcf8bc90e57a65c1d03d68594d3f0", secret2: "b47f3ba965fbea51c927b6846543480aeb25275c0e01c5c4d286ea087e70ee92", nonce: "6c9820a69d021d86a695eb3d5cc11ec638a799aca10ecfb9819b1efa3b9731ff", kind: 1, scopeHex: "ef8080", patternHex: "ff", repeatCount: 65532, ciphertextSha256: "6621fc89a79464d19cbef605d962c9f43af90568c8c352007829445d1886c9bf"),
        .init(secret1: "38c961d0c8289789cec189e8db140f740abf34c8251eb16ad93cc5f9021abeb3", secret2: "e985cda5e08979c17a2c148532434c6f830bc2243e7a5592704972328f24d62d", nonce: "3957e9cc3be20433aff61993558572099e186312e714050cd3a589ff675f0e07", kind: 1, scopeHex: "efbbbfefbfbe", patternHex: "ff", repeatCount: 131068, ciphertextSha256: "e41d7c737462f18b653683796d739c3b93f284c9bc15182bd94d278d13b84dea"),
        .init(secret1: "0666935a88d5196746c799ce0593dede7a8e8044930e62e07793950b9dab9b4d", secret2: "e3505f4e3b8fd37da2a9b4f3cb67864819e6272cdcdcf198f422598fa1114d21", nonce: "56fef50b564913b040a9ee83c9c1eb36ac6553a9e5ad699ac036fb4338a38e35", kind: 1, scopeHex: "e381afe4b896e7958c", patternHex: "ff", repeatCount: 262140, ciphertextSha256: "086aaa494e3a4ca5bc573d91fbed292d9abe05fb730c54660bf5813250744aab"),
    ]

    // MARK: - decrypt_only (5)

    private static let decryptOnlyVectors: [DecryptOnlyVector] = [
        .init(secret1: "fce6ddb6b9611964b37466e29f89f212f6905a70e5b0ea20b33ac9a4a74e60cb", secret2: "45d28e26e1072c9495857efc85bb56ba0833271d7cb183c6459b8ca17311ed7e", nonce: "d55b86093a16aabd228b9ac1724749e492fc3a81491c7374bd7a1d28a7b3b4a3", kind: 1, scopeHex: "", plaintextHex: "efbbbf48656c6c6f20776f726c6421", ciphertextB64: "A9Vbhgk6Fqq9IouawXJHSeSS/DqBSRxzdL16HSins7Sji9VE1vdW4PQiqseqUsGZsaAvIe2yGmfWOXiimOZHRUUAAAABAAAAAHm5SMpSTmibFgS1CqDSU5sC6MEPKNyTHS7oxNAb/AAFwta2Xpcc", note: "non-standard padding (23 bytes instead of 17)"),
        .init(secret1: "099f9dd917f81a515d587164ed21bfcc3897bf705a7c9b3de85abcea809831df", secret2: "9806d1447c80921a15ff6c737204d985fbee09a6fb123ec8c1ef8749a939ac6d", nonce: "382baacbba8cba0cc6e8a7b4444fb157186118a18b3dbf652fb6b1e8267bcac1", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", plaintextHex: "6e6f7374722e6c616e64206e697034347633", ciphertextB64: "Azgrqsu6jLoMxuintERPsVcYYRihiz2/ZS+2segme8rBD0AqKypuSHff1x0FW+qO4lQlLltEjPWrvoMo7fbKOfwAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYznEO1UCJd2Ld0YV51u6kOkY3g22UhvNBAXY3sFnKmPu6fYx9s0rDWwNZcGxsMs+VydrONvM5F", note: "non-standard padding (36 bytes instead of 14)"),
        .init(secret1: "a62c0eae8281f8997c6391889be1c39df8d06acbde7cbb5e23b8e6ba28c95328", secret2: "c51b92dfea8551090c2e17d22953f7124fdd6a59e7c67daadcb92819279801d4", nonce: "f08ea755450d9666cc122f2aa89794b170b8c69c6d7ff5f1d25bfae52164ca3a", kind: 1, scopeHex: "e381afe4b896e7958c", plaintextHex: "f09f9088f09fa694", ciphertextB64: "A/COp1VFDZZmzBIvKqiXlLFwuMacbX/18dJb+uUhZMo6uAhk3+WwQOcgQUgH4zhxaRzi80m70t5a9uV5B11EdpcAAAABAAAACeOBr+S4lueVjPeRbg5pf83dLf79+g1wPXb8mjm/rT9e", note: "non-standard padding (15 bytes instead of 24)"),
        .init(secret1: "740853175b987393b113ac196ccf5152ed4a206b1a365291abacaf106c7a3bca", secret2: "da1a37af7852a7e5c0a7ce90a39950039bfaeab96297ef83b9d8817f5a2d26f9", nonce: "f7e0f4b83ebb87657001b8e47d5940a3d062dfebae66da5a2ad0f4e498fedf85", kind: 1, scopeHex: "efbbbfefbfbe", plaintextHex: "e69a97e58fb7e58c96e381aee3819fe38281e381aee382a2e382afe382bbe382b9e588b6e5bea1e6a99fe883bde3818ce799bbe5a0b4e38197e381bee38197e3819fefbc81", ciphertextB64: "A/fg9Lg+u4dlcAG45H1ZQKPQYt/rrmbaWirQ9OSY/t+Fhm1xiEi20bWbMLIDrNw7Gz6XU0bDmmmgYl3g4z68Z+4AAAABAAAABu+7v++/vhLMBXKVPi51crCqEwCQnuB0V13+nE22PpVe7jQiELzDMqdrE6intBrXyHJLrJ4VteEZoiU92jZDoG9ieltDh0NnKRKq7cuW/om3DIhB0DCb0Pq6C5g/VaFaz2+mVPXV0p2BMW2MpuKUJ7/VYAlJPNSlK/JSYpQq", note: "non-standard padding (50 bytes instead of 27)"),
        .init(secret1: "28531e3c28be034f8bcca7bc25e5b9a6cbbcce8567f2a9016b3f1ad7707a724a", secret2: "96108e608b4231562b07d21021361e3efab87350021a9247ce410585c0adf757", nonce: "a82a808ca1a40368336f19e9d3f83bfaaa35e4b8bffc9b5d9426ae518b9f34d1", kind: 1, scopeHex: "ef8080", plaintextHex: "9b8de973ddf42a02103de24d9b7a4f0c4f551abaf7cd88f08e7a9c4d41ec5f777b45c890c112968fee50dccd3287583e9a3a33f962d78054f36dcb6f1ea9a8aa3fcb80953e04f6a2b3c3c4e26909ef7c5e84da6df3fd423215015640b249c91b28b38b18499b615bf1e92635e1df15aeeba2063692ce7cc8296582ceed25ceda", ciphertextB64: "A6gqgIyhpANoM28Z6dP4O/qqNeS4v/ybXZQmrlGLnzTRH0t5gnTV0ylQcxxkbLRHyKXnIagqYk5XMlG/85NYwuwAAAABAAAAA++AgM9zXmWWTYSixZDotwM+8HmJHW3aBt44KvZkhInVvt+Xmzh1YaPW8cbVr9kOQ38+cc5E285UfL164P71915Pr6mHNGOHtpKcX3P6TXCrch2MLux4m9xHf0BPcuv4+bwC0fLpNKVJLnNAnnGm7VOXdE2HhX4NP8ujzvH6cKTGfiyK0OlVpWX6Le+v/h2wm6m2SAHSJLbi6fIdA6MDilizVMqyaEFZ3n8eRYQ+To6eFKojRQw=", note: "non-standard padding (50 bytes instead of 64)"),
    ]

    // MARK: - invalid_decryption (19)

    private static let invalidVectors: [InvalidVector] = [
        .init(idx: 0, secret: "b2a4cca9347992d235fe115382098e313f6eaa3680248443b90c64e4e2ab039e", publicKey: "dc62907f84a35acecfc55b6d82961399f019981be0cd7d5e6a5a0620f9158870", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "Awx1nilOH4b0PT+ZszAS4TqOfADUQxWfAHAUVyJmy7c8EvrgFmKouWAVFZyjYN2XuuGSWHlKeuo9bF9t7MwMGfwAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzVeOxtyTClFO2/OPL6lpuSi3WFTdQgbhX6g/f1Iv2K6o=", why: "invalid MAC"),
        .init(idx: 1, secret: "83ed5a7ae0494831e938a0a8226472954be9daffb4bf5d7641473b35e959cf90", publicKey: "90ecf0dd8a793c74809735cc37cc3b9de20ffc9aae0eae7a1a0c740ecf09e395", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "A90ZzLN2HaQRTrzzLoobOtW+c9GyPxVp64fhIygpEpLaYYbCN6Pq1rjptBbN5S2vCFPCsE3wmU5u3Wx6L8oZxJoAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYz8Sxek35q19YWqmhyQNRHVZ+sNTtdgXO3MCnvjw0nanb233a39sc969Lm5DaUPN+yTKV0NbtYYN5hIWDOMOXj63XtzT7S7i/LAhv/l8y1zLTc0aUUoIjEg0EHi/FvlakK", why: "invalid MAC"),
        .init(idx: 2, secret: "efd2ac18f500ac0fa1b9639149432ff2d309d1b49c7f683c9ca4613d14449dce", publicKey: "84194beab56b44c426b866261772bc0a447ea34f94f2317ce1350cb714021a25", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "A5vkMZfJPQuWeOQsEiuZX1M4VJLY/k2G1mL8EKHK/yq7gifeC4V4zQ4L1iiQ1oVgmTmhwb/vd21Fm3YZrpYGEvYAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzQlapufh4trECMJjdb8m/TNFFcFJJSmiM/XQpnKXM/wc=", why: "invalid padding"),
        .init(idx: 3, secret: "2926c352495ce986639ccbb263ad2221df731bae6ee8ec329cbb5d00c5b9ca87", publicKey: "3c4b835fc7de0dd3a02971b559ccd5d3bcd2eb3cce7c1023b93892918effb71d", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "AzW5Wy/bvTYdcVOLIL8W26mfgTFG19S0H2BC9kyqgqK+TZ8oI00WJTNqwJIg8JE7DqDnOY+Q40Yd3G8Hi4GobQ8AAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYz3cI/rKzcQ22idVIBuFgLEVJaK1W5uxh6M6AdMoKKtdxO+lESYYWCEh/zzj35MFMwSJTn8z+XFvv9f2jYgQXHvPmY13wLOpIrpoS2W8luUbOVf9fip5mZXHw3neYvc7jA", why: "invalid padding"),
        .init(idx: 4, secret: "47c04c4c6d385ddaaef691bd58dab94f81f4ba9eb1ab832339c3d0042f998dc5", publicKey: "cb6a3aa6d94a58c9f03354a2a8723c3449e06b19a0ccfe19353195b28ddf7694", kind: 1, scopeHex: "e381afe4b896e7958c", ciphertextB64: "#A2A/tbfDDqn4qx267aPFZDwyH78j9zZV8g8ekZKonH8bDR7vYhp7zzh3oJAlJWem/Z5OVrRvUAJQrx8q289PqsEAAAABAAAACeOBr+S4lueVjASdOe8pTxevoZoYq1Y8rRarB6+yzRlquT4RZlmHH3jLEQmAbBjQGrOXi1uWPbaKC8j/VpjW5S9BAtyMSMpUcHg=", why: "unsupported future version"),
        .init(idx: 5, secret: "751321afdaaf76aeb87851ca8f35eab87d0f50e1ec595c67e7e37ced7d6b7b9a", publicKey: "a340bd34205bb0f3dc2f9aa3fcb70fc52c326cc4566c457bb9cfb9ae17c239af", kind: 1, scopeHex: "e381afe4b896e7958c", ciphertextB64: "AP9SHg4CFoD4fy22vSMNZV+efP7Ld7GCOpIKeZANqL+Kspe380sGxRQGKyy/liCuMi8DbcfQJypivkS+Y/bz3sIAAAABAAAACeOBr+S4lueVjMM0jKIQIfjKuEBBmjWPFmQsB20qe5pcJiLpnnXmp12z", why: "unsupported version 0"),
        .init(idx: 6, secret: "c4ca1bf68b1f768bbc3670d554036b5c892303319ed6f7228e8dc2f6c99dd0b3", publicKey: "537986db4ffe564eb7d565643e78dbc24e86650957e6e7c2c8d0124fd04fd68f", kind: 1, scopeHex: "", ciphertextB64: "Ap2Mv1HTQrVArE2UVevKq7rQ+a0FMw8OBuiAMnA81jJit7c0QzkEMr/o+5++t0/FbXFABfQaTRpF+dBuISyw3rEAAAABAAAAAC5e+Y9lfvgD1trmXL2Jv5H3Khi8ayWJJQMrVOEMd9tlJNj1b7k/ZzIG71f2GBzzoeBImA2fk+q6Iix4v5jUulo=", why: "unsupported version 2"),
        .init(idx: 7, secret: "9460c5781801b35f01c1093434266cab5ba997014c52d9a16c3772f8580ac61b", publicKey: "375cf44101e7d77699da6b8d7e633f507eaa82720d4d3cea1c0db85447975fa3", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "BAahtRKP0WL8luCz9m6TydiQtWUfoIWvkRlg2tatPVOCAwYrO8Dw3DZMgeTGjaehohfAmVyZ6SneuTQF3Ho+EUIAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzpHJCeyhgMaqIsPgWO635BaIwmRU4cfe9aA6gGqGI7SY=", why: "unsupported version 4"),
        .init(idx: 8, secret: "b46bd96a998b00b55e48ad76c1fa0c68bc64b94174a189983b689fc05a0cec52", publicKey: "797b06ba5dd8ca23a8c8cae4e9ee8963b25d9bf92618fa0b62db1ddc7b611453", kind: 1, scopeHex: "ef8080", ciphertextB64: "", why: "empty payload"),
        .init(idx: 9, secret: "42602869f3d35e0bb04f72e3053d8de9cccf1e78dd6926c9311134784a5e70d6", publicKey: "94a4ac3a4bf998dc64ab07cbb573ecb045e028f9b19c88f02af8f73d334ba0bd", kind: 1, scopeHex: "efbbbfefbfbe", ciphertextB64: "Aw==", why: "payload only has 1 byte"),
        .init(idx: 10, secret: "d2dccc683567cd0cc6d9ec907703ddb362ecb61ef8e6c8ebb7411a293230935a", publicKey: "294da03d650400e766953c9fb78600b788598a35e47b9755a891802de76f7a09", kind: 1, scopeHex: "ef8080", ciphertextB64: "A6oBqSSHPckKYt8Doymo2s1ku7LJxSNSfSuQdBoXaRe8q+5FQmvwbejIzJEaVKdUhbykNt5VFxno+sZtreNhrHgAAAABAAAVCO+AgAnTQMJrGJX7muna+wwIyM82vR398H+fhL6XxOam03jQErUC9W+klrNflk6oJ4mmyO88x6FJcf6n6LfDpGjMogNuMxoR1crWfknPMJuHggEUfOU6AjN7CgGiFPdnfcgbUPP487vxX9iw7U8WhQCfnh46vQTdwCDIm0C3aUp2/fJ0xNTVIZkFVKV1CyvyFpVicY9Zc7fmeEIDAsJvM1beK9sWqp9CI/sMU9OXmTfjdugSuisDRevchLkr6h5kB/rXDw==", why: "scope length out-of-bounds"),
        .init(idx: 11, secret: "e1ef663aeb335452c9670d8a9f1f75cae5077f216314e9b49761610b4eb98538", publicKey: "b729446e5cdbd2e4ac7967b056c17d5e4735035f2d2cf829722a0a85ca1fb6cb", kind: 1, scopeHex: "efbbbfefbfbe", ciphertextB64: "A/uzxqp0UwE6j7p8PIRKJDa0ah39GGyMbM0fOivlqESqbfFnp5OD2FSHR9TOTeJwiAfLXcXkoZPwiNKjB4ZgXV4AAAABAAAABu+7v++/vm7l8A==", why: "ciphertext too short"),
        .init(idx: 12, secret: "327ffef01143a4dae30e201add671183424b39b1f33f64d78c19c22d3a7e790c", publicKey: "039f6ce0144af03f0f3caf8a070a6a36519e2942286c2295a23785b0668ea621", kind: 30078, scopeHex: "737065632e6e6f7374722e6c616e642f6e697034347633", ciphertextB64: "A5jnLthci6SRC9V9Ak/AKGyB7xAGPLGZx+fW9wjfvOKQuug5cUUGX4R0mmxFHl5/TtcQ4syIiTtgXL3uVveIP3MAAHV+AAAAF3NwZWMubm9zdHIubGFuZC9uaXA0NHYzS3rEqFHqpL5Yqh/xY+a9i0XAyY960LDSfzQjSZh4UHzbuxmMEk92jAczsFkI9cWqd+xzahX59yD9l+UnCw3o9yXmzZIaA6UYPFI20f2VnH+G6F0Zt917fgt0bJwR3QUwblT63eOKLJGYhXqC11dweuKORW6oGJagRFo7P8r3UIFTHPkL5xMhUtZS7TS7GDKTB7kmEp5trwfzboiWxzp12LSlkUU9Nctyf6KE4iEQbk2jDndbC9npCn1rFpsFiHsd!", why: "invalid base64 (trailing)"),
        .init(idx: 13, secret: "53d492157f17e6804bacdef3942fbb220a7239aab0e6bd6355eb3ff989ea0076", publicKey: "ad2e1f00a4d5985810072cea336b0670f8e924368bca5b15c84ba8f3d7cae478", kind: 1, scopeHex: "e381afe4b896e7958c", ciphertextB64: "A3oG29gbEA%8QXjVLA5JeYOl1Hj5bJVaNcl2tAnfEHm5pzS0V+3eF8Tns8+A+TkfxrSc3DuAbkxc9SgWC+214cBIAAAABAAAACeOBr+S4lueVjGfB4CLk22vLao5NE6OH5KlgzSy++iyD7FZEmAkCVOfQkrnbj9kzyLF7HRygI5E2FJdeQkX6WDiHtwzP/UWwd+cnMaXTYS7vL0Zh6Lvz/PKicCecxB0NvkAdYM3hOpodhXEYd2nano+37mU1Cahp2uwyygJQTb427cHBucQiVpIadVoKqMeIA7EGvO9HTgTxgE93vyT26NqZFO9aniV1bFc7y9nq1OYHFfNQgzdxVMTQ88SwMbq2TSpU5uJc/cphNA==", why: "invalid base64 (middle)"),
        .init(idx: 14, secret: "d4db7f6dcf6a45843739a806876a9da849f75f7a36702e7b4f7a10a986bf76cd", publicKey: "0377961328c3bb0db459cd22033d7a7ca1e29d7f42fd3f1b038530a2402879c8", kind: 1, scopeHex: "", ciphertextB64: "Ay1pBSibePLV49S4vfkgB4GCHR0Xywd7acm1WoC1ZaX6Jg38sM0PQAshZtniNKpUjQWZGw4e7kSKEgFIGhT6SxQAAAADAAAAABuabdmj5F6vlFssb3CHu/ndTMpdcPSWXklapkGwxJRS", why: "context mismatch (kind)"),
        .init(idx: 15, secret: "b00e9f068deb4b69c474109502839c981bd429075eeab9e5f41db9022c0cd869", publicKey: "6de2d6a91eb75f5e6038d633da8695f35fad807d5bad6b9e25ae8f526e10c05f", kind: 1, scopeHex: "68656c6c6f20776f726c6421", ciphertextB64: "A49dkIXX4dVAn6A9ql4cQ3MQfoU7rPrsg9/8V8d5NL9+A7Ntb9VIbBQ4V2ORFXS5rzOkHhZkKmtnn3dpMUiQWwsAACcQAAAADGhlbGxvIHdvcmxkIRb3rRdfIPuJvtEnjn6dj7RgKg1OUvGmCQoXmp+32EN6XL+vEHnbIbvLWLqIV7eCAmOqrPVGngCJEppHzzFMuhM=", why: "context mismatch (kind)"),
        .init(idx: 16, secret: "e150f3f5fd2eb47c49e8c1ee0ca51d3502d370108a98519d212731746fc513c2", publicKey: "901f54e63d0d1df5bf120e12faf00d6e4ec3c6d9fe81e0dc0f35cf1d5a489ac2", kind: 30078, scopeHex: "6170706c69636174696f6e2d64617461", ciphertextB64: "A/JaJhlnuKYJhr6LdZ46lkK7cw0nxGvA4rp112e70q0O9jMnXxaWqqNE7nZnllwl7yuGWRtcLU2q6uWAUZ6wthIAAHV+AAAAD2luY29ycmVjdC1zY29wZZ++z1BEvaKntWN9G+9EIT0da0luVAV/hAvOoUg90pXE4C6nsAKmpZ3Q2YfAvtUDlkMpxPv4u10Rlz0VGlPo9GtcGJp4X2aq/5gdbTZJF8mxnkhZ4zQqwRibV0JJ0ZNZxg==", why: "context mismatch (scope)"),
        .init(idx: 17, secret: "1c9c9ff5df8a9ff99e50b3dac27d987422567e9122075097edea2915e12580ca", publicKey: "32178882654a70441f1c507902ae3a89888ecd2266930a45f8d6b2f578643307", kind: 4, scopeHex: "efbbbf", ciphertextB64: "A3c7VODzMr9mQXQNRtw3MQsntesGokh3g8nQwdAK4iWqL/nV6HPOhnz5xFf1UjyvTrHJC8BrGjRefguMrJLrfy8AAAAEAAAAD2luY29ycmVjdC1zY29wZfvq9zBo8LQrHyulrPg0swuPZs4W3Xy1TSQlmczZ643aOllm+9DveIcqoXoQaGQTs1RDLeekOMNquv9a5XMWZ431ysJ44L3ET4Ztw5Eevnxx3pgaob8bCikyuGT+5CyR2A==", why: "context mismatch (scope)"),
        .init(idx: 18, secret: "18a8c52a7d94c36bf08ec04336247ab2c67014b964a3e33f3d6677e697f2008c", publicKey: "d1069a731110484f212fa9fe2fa4dcd2e2c0857b5e0dda1bd5667901ce303d81", kind: 4, scopeHex: "ff", ciphertextB64: "A3PSjybYp19qos4LlMKEdlPQShJIBOJBGjjOI6etumpU4VaN0LYMB8qECxbwF7ebuv2Lxu5h0yXtNpdJtX4Z5fgAAAAEAAAAAf+AeTttkffcDMHUCDRxKYA3p7nnmK2hNvB04X0VP2H27Q==", why: "invalid scope (not valid utf8)"),
    ]

    // MARK: - 1. encrypt_decrypt round-trip via PUBLIC API

    /// For each `encrypt_decrypt` vector:
    ///  1. `_testOnly_encrypt` with the JSON-supplied nonce → must equal the
    ///     spec's `ciphertext` byte-for-byte (proves the full composition
    ///     chain is in sync).
    ///  2. `decrypt` from secret1's perspective → recovers plaintext.
    ///  3. `decrypt` from secret2's perspective → also recovers plaintext
    ///     (proves bidirectional ECDH).
    func testEncryptDecryptVectorsRoundTrip() throws {
        var failures: [String] = []
        for (i, vec) in Self.encryptDecryptVectors.enumerated() {
            do {
                let seckey1 = try Self.hex(vec.secret1)
                let seckey2 = try Self.hex(vec.secret2)
                let pub2 = try Self.pubkey(forSecret: vec.secret2)
                let pub1 = try Self.pubkey(forSecret: vec.secret1)
                let plaintext = try Self.hex(vec.plaintextHex)
                let nonce = try Self.hex(vec.nonce)
                let context = try NIP44v3.Context(kind: vec.kind, scope: try Self.hex(vec.scopeHex))

                let encrypted = try NIP44v3._testOnly_encrypt(
                    seckey: seckey1, pubkey: pub2,
                    context: context, plaintext: plaintext, nonce: nonce
                )
                if encrypted != vec.ciphertextB64 {
                    failures.append("vec[\(i)] encrypt byte-equal failed")
                    continue
                }
                let decoded1 = try NIP44v3.decrypt(
                    seckey: seckey1, pubkey: pub2, context: context, ciphertext: vec.ciphertextB64
                )
                if decoded1 != plaintext {
                    failures.append("vec[\(i)] decrypt(secret1) plaintext mismatch")
                }
                let decoded2 = try NIP44v3.decrypt(
                    seckey: seckey2, pubkey: pub1, context: context, ciphertext: vec.ciphertextB64
                )
                if decoded2 != plaintext {
                    failures.append("vec[\(i)] decrypt(secret2) plaintext mismatch")
                }
            } catch {
                failures.append("vec[\(i)] threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 2. long_encrypt_decrypt SHA-256 + round-trip

    /// For each large-message vector: encrypt with injected nonce, hash the
    /// resulting wire (as ASCII base64 bytes per spec convention), and
    /// confirm it matches the expected SHA-256. Then decrypt and confirm
    /// plaintext recovers.
    func testLongEncryptDecryptVectorsMatchSHA256AndRoundTrip() throws {
        var failures: [String] = []
        for (i, vec) in Self.longVectors.enumerated() {
            do {
                let seckey1 = try Self.hex(vec.secret1)
                let pub2 = try Self.pubkey(forSecret: vec.secret2)
                let nonce = try Self.hex(vec.nonce)
                let pattern = try Self.hex(vec.patternHex)
                var plaintext = Data()
                plaintext.reserveCapacity(pattern.count * vec.repeatCount)
                for _ in 0..<vec.repeatCount { plaintext.append(pattern) }
                let context = try NIP44v3.Context(kind: vec.kind, scope: try Self.hex(vec.scopeHex))

                let wire = try NIP44v3._testOnly_encrypt(
                    seckey: seckey1, pubkey: pub2,
                    context: context, plaintext: plaintext, nonce: nonce
                )
                let sha = Self.sha256Hex(Data(wire.utf8))
                if sha != vec.ciphertextSha256 {
                    failures.append("long[\(i)] SHA mismatch: got \(sha), want \(vec.ciphertextSha256)")
                    continue
                }
                let recovered = try NIP44v3.decrypt(
                    seckey: seckey1, pubkey: pub2, context: context, ciphertext: wire
                )
                if recovered != plaintext {
                    failures.append("long[\(i)] round-trip plaintext mismatch")
                }
            } catch {
                failures.append("long[\(i)] threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 3. decrypt_only — non-standard padding tolerance

    /// The 5 vectors in this category specifically test that decrypt
    /// accepts non-standard padding lengths. Catches Amber-PR-#448-style
    /// regressions where an implementation recomputes
    /// `target_size(plaintextLen)` and rejects mismatches; spec commit
    /// `c6daedd` forbids that check. Validates the gotcha flowing through
    /// all four composed layers, not just the Encryption layer in isolation.
    func testDecryptOnlyVectorsTolerateNonStandardPadding() throws {
        var failures: [String] = []
        for (i, vec) in Self.decryptOnlyVectors.enumerated() {
            do {
                let seckey1 = try Self.hex(vec.secret1)
                let pub2 = try Self.pubkey(forSecret: vec.secret2)
                let expected = try Self.hex(vec.plaintextHex)
                let context = try NIP44v3.Context(kind: vec.kind, scope: try Self.hex(vec.scopeHex))
                let recovered = try NIP44v3.decrypt(
                    seckey: seckey1, pubkey: pub2, context: context, ciphertext: vec.ciphertextB64
                )
                if recovered != expected {
                    failures.append("dec[\(i)] (\(vec.note)) plaintext mismatch")
                }
            } catch {
                failures.append("dec[\(i)] (\(vec.note)) threw \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 4. invalid_decryption — top-level error mapping

    /// All 19 invalid_decryption vectors map to the appropriate top-level
    /// `NIP44v3.Error` case (or `Context.Error.scopeNotUTF8` at construction
    /// time for vector 18).
    ///
    /// Mapping:
    ///   - 0-3   (MAC/padding tampering)   → `.decryptionFailed`
    ///   - 4-7   (version-byte rejection)  → `.unsupportedVersion(byte:)`
    ///   - 8-11  (framing/size rejection)  → `.invalidCiphertext`
    ///   - 12-13 (base64 parse)            → `.invalidCiphertext`
    ///   - 14-17 (kind/scope mismatch)     → `.decryptionFailed` (MAC fails
    ///     because caller-supplied context disagrees with the bound context)
    ///   - 18    (UTF-8-invalid scope)     → `Context.Error.scopeNotUTF8`,
    ///     before any crypto runs
    func testInvalidDecryptionVectorsRejectWithCorrectError() throws {
        var failures: [String] = []
        for vec in Self.invalidVectors {
            let label = "invalid[\(vec.idx)] (\(vec.why))"
            // Index 18: Context.init rejects before decrypt is called.
            if vec.idx == 18 {
                do {
                    _ = try NIP44v3.Context(kind: vec.kind, scope: try Self.hex(vec.scopeHex))
                    failures.append("\(label) Context init UNEXPECTEDLY SUCCEEDED")
                } catch let e as NIP44v3.Context.Error where e == .scopeNotUTF8 {
                    // expected
                } catch {
                    failures.append("\(label) wrong error: \(error)")
                }
                continue
            }
            do {
                let seckey = try Self.hex(vec.secret)
                let pub = try Self.hex(vec.publicKey)
                let context = try NIP44v3.Context(kind: vec.kind, scope: try Self.hex(vec.scopeHex))
                _ = try NIP44v3.decrypt(
                    seckey: seckey, pubkey: pub, context: context, ciphertext: vec.ciphertextB64
                )
                failures.append("\(label) UNEXPECTEDLY SUCCEEDED")
            } catch let e as NIP44v3.Error {
                let ok: Bool
                switch vec.idx {
                case 0, 1, 2, 3:
                    ok = e == .decryptionFailed
                case 4, 5, 6, 7:
                    if case .unsupportedVersion = e { ok = true } else { ok = false }
                case 8, 9, 10, 11, 12, 13:
                    ok = e == .invalidCiphertext
                case 14, 15, 16, 17:
                    ok = e == .decryptionFailed
                default:
                    ok = false
                }
                if !ok {
                    failures.append("\(label) wrong NIP44v3.Error case: \(e)")
                }
            } catch {
                failures.append("\(label) non-NIP44v3.Error: \(error)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures:\n" + failures.joined(separator: "\n"))
    }

    // MARK: - 5. Context UTF-8 validation

    /// Valid UTF-8 scopes — ASCII, multi-byte CJK, emoji, BOM — all
    /// construct successfully without normalization.
    func testContextAcceptsValidUTF8Scopes() throws {
        let cases: [(String, Data)] = [
            ("ASCII", Data("hello".utf8)),
            ("multibyte CJK", Data("日本語".utf8)),
            ("emoji", Data("🐈🦤".utf8)),
            ("BOM prefix", Data([0xef, 0xbb, 0xbf]) + Data("hi".utf8)),
        ]
        for (label, scope) in cases {
            do {
                let ctx = try NIP44v3.Context(kind: 1, scope: scope)
                XCTAssertEqual(ctx.kind, 1, "\(label): kind round-trip")
                XCTAssertEqual(ctx.scope, scope, "\(label): scope passed through unmodified")
            } catch {
                XCTFail("\(label) threw: \(error)")
            }
        }
    }

    /// Each invalid UTF-8 byte sequence must throw `.scopeNotUTF8`. Includes
    /// the spec `invalid_decryption[18]` vector's `scope_hex` (`0xff`).
    func testContextRejectsInvalidUTF8Scopes() {
        let cases: [(String, Data)] = [
            ("lone 0xff (spec vec 18)", Data([0xff])),
            ("lone continuation 0x80", Data([0x80])),
            ("truncated 2-byte start", Data([0xc3])),
            ("truncated 3-byte start", Data([0xe6, 0x97])),
            ("overlong NUL (C0 80)", Data([0xc0, 0x80])),
        ]
        for (label, scope) in cases {
            do {
                _ = try NIP44v3.Context(kind: 1, scope: scope)
                XCTFail("\(label) Context init UNEXPECTEDLY SUCCEEDED")
            } catch let e as NIP44v3.Context.Error {
                XCTAssertEqual(e, .scopeNotUTF8, "\(label)")
            } catch {
                XCTFail("\(label) wrong error: \(error)")
            }
        }
    }

    /// `Context(kind:)` is the non-throwing convenience for the empty-scope
    /// case (kind 1, kind 4, kind 1059, etc — anything without a `d` tag).
    func testContextEmptyScopeConvenienceInit() {
        let ctx = NIP44v3.Context(kind: 1059)
        XCTAssertEqual(ctx.kind, 1059)
        XCTAssertEqual(ctx.scope, Data())
    }

    // MARK: - 6. Random-nonce smoke test

    /// Two consecutive encrypts with the PUBLIC API (no injection) MUST
    /// produce distinct wires — proves the nonce-generation path is wired
    /// up and not accidentally constant. Both wires MUST decrypt back to
    /// the same plaintext.
    func testRandomNoncePublicAPIProducesDistinctRecoverableWires() throws {
        let seckey1 = try Self.hex("1b7023bb70248d8edab44658c5e2677dd7e5d7093ec062eb204975df4255fddc")
        let pub2 = try Self.pubkey(forSecret: "827844538be12d1cfa0f7fa096668cc4f2c4a25c2c8f7e92ca6cb05c3c445d17")
        let context = NIP44v3.Context(kind: 1)
        let plaintext = Data("hello via public API random-nonce path".utf8)
        let wire1 = try NIP44v3.encrypt(
            seckey: seckey1, pubkey: pub2, context: context, plaintext: plaintext
        )
        let wire2 = try NIP44v3.encrypt(
            seckey: seckey1, pubkey: pub2, context: context, plaintext: plaintext
        )
        XCTAssertNotEqual(wire1, wire2, "consecutive encrypts must differ (random nonce)")
        let dec1 = try NIP44v3.decrypt(
            seckey: seckey1, pubkey: pub2, context: context, ciphertext: wire1
        )
        let dec2 = try NIP44v3.decrypt(
            seckey: seckey1, pubkey: pub2, context: context, ciphertext: wire2
        )
        XCTAssertEqual(dec1, plaintext)
        XCTAssertEqual(dec2, plaintext)
    }

    // MARK: - 7. Edge cases

    /// Empty plaintext must encrypt and decrypt successfully — the
    /// padding-prefix accounts for length 0, the chacha20 stream still
    /// runs on the 32-byte minimum padded block, and MAC verifies.
    func testEmptyPlaintextRoundTrip() throws {
        let seckey = try Self.hex("1b7023bb70248d8edab44658c5e2677dd7e5d7093ec062eb204975df4255fddc")
        let pub = try Self.pubkey(forSecret: "827844538be12d1cfa0f7fa096668cc4f2c4a25c2c8f7e92ca6cb05c3c445d17")
        let ctx = NIP44v3.Context(kind: 1)
        let wire = try NIP44v3.encrypt(seckey: seckey, pubkey: pub, context: ctx, plaintext: Data())
        let recovered = try NIP44v3.decrypt(seckey: seckey, pubkey: pub, context: ctx, ciphertext: wire)
        XCTAssertEqual(recovered, Data())
    }

    /// Wrong-length seckey at the public encrypt boundary surfaces as
    /// `.invalidKey` (mapped from `Keys.Error.invalidSecretKeyLength`).
    func testEncryptRejectsWrongLengthSeckey() throws {
        let badSec = Data(repeating: 0xaa, count: 31)
        let pub = try Self.pubkey(forSecret: "827844538be12d1cfa0f7fa096668cc4f2c4a25c2c8f7e92ca6cb05c3c445d17")
        let ctx = NIP44v3.Context(kind: 1)
        do {
            _ = try NIP44v3.encrypt(seckey: badSec, pubkey: pub, context: ctx, plaintext: Data("x".utf8))
            XCTFail("expected throw")
        } catch let e as NIP44v3.Error {
            XCTAssertEqual(e, .invalidKey)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// Wrong-length pubkey at the public decrypt boundary surfaces as
    /// `.invalidKey` (mapped from `Keys.Error.invalidPublicKeyLength`).
    func testDecryptRejectsWrongLengthPubkey() throws {
        let seckey = try Self.hex("1b7023bb70248d8edab44658c5e2677dd7e5d7093ec062eb204975df4255fddc")
        let badPub = Data(repeating: 0xbb, count: 33)
        let ctx = NIP44v3.Context(kind: 1)
        let validWire = Self.encryptDecryptVectors[0].ciphertextB64
        do {
            _ = try NIP44v3.decrypt(
                seckey: seckey, pubkey: badPub, context: ctx, ciphertext: validWire
            )
            XCTFail("expected throw")
        } catch let e as NIP44v3.Error {
            XCTAssertEqual(e, .invalidKey)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Wire kind / scope tamper tests
    //
    // Validates the spec step-4 check ("Fail if kind != expected_kind / scope
    // != expected_scope") in `NIP44v3.decrypt`. Without it, a wire whose
    // embedded kind/scope bytes are tampered but whose MAC tag is intact
    // would silently decrypt successfully whenever the caller's context
    // matches the original encryption (which it always does for legitimate
    // use), so the spec invariant "embedded context is authenticated" would
    // be only partially enforced.

    /// Tamper one byte of the embedded `kind` field in a valid v3 wire and
    /// verify decrypt rejects with `.decryptionFailed`. Uses vector 0 which
    /// has kind=1 and empty scope.
    func testDecryptRejectsTamperedEmbeddedKind() throws {
        let vec = Self.encryptDecryptVectors[0]
        let seckey = try Self.hex(vec.secret1)
        let pubkey = try Self.pubkey(forSecret: vec.secret2)
        let ctx = NIP44v3.Context(kind: vec.kind)

        guard var rawWire = Data(base64Encoded: vec.ciphertextB64) else {
            return XCTFail("vector 0 base64 decode failed")
        }
        XCTAssertGreaterThanOrEqual(rawWire.count, 69, "wire too short to tamper kind")
        // Flip the low byte of kind (offset 68) to a different value.
        // MAC tag (offset 33..<65) is NOT touched.
        rawWire[68] ^= 0xff
        let tamperedB64 = rawWire.base64EncodedString()

        do {
            _ = try NIP44v3.decrypt(seckey: seckey, pubkey: pubkey, context: ctx, ciphertext: tamperedB64)
            XCTFail("decrypt should have rejected tampered embedded kind")
        } catch let e as NIP44v3.Error {
            XCTAssertEqual(e, .decryptionFailed,
                           "tampered embedded kind should surface as .decryptionFailed (see spec step-4 doc comment in NIP44v3.decrypt)")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    /// Tamper one byte of the embedded `scope` field in a valid v3 wire and
    /// verify decrypt rejects with `.decryptionFailed`. Uses vector 1 which
    /// has kind=30078 and a non-empty scope.
    func testDecryptRejectsTamperedEmbeddedScope() throws {
        let vec = Self.encryptDecryptVectors[1]
        XCTAssertFalse(vec.scopeHex.isEmpty, "test requires a non-empty-scope vector")

        let seckey = try Self.hex(vec.secret1)
        let pubkey = try Self.pubkey(forSecret: vec.secret2)
        let scope = try Self.hex(vec.scopeHex)
        let ctx = try NIP44v3.Context(kind: vec.kind, scope: scope)

        guard var rawWire = Data(base64Encoded: vec.ciphertextB64) else {
            return XCTFail("vector 1 base64 decode failed")
        }
        // Scope starts at offset 73 (after version(1) + nonce(32) + mac(32)
        // + kind(4) + scope_len(4)). Flip the first scope byte.
        XCTAssertGreaterThan(scope.count, 0, "vector 1 scope unexpectedly empty")
        XCTAssertGreaterThanOrEqual(rawWire.count, 74, "wire too short to tamper scope")
        rawWire[73] ^= 0xff
        let tamperedB64 = rawWire.base64EncodedString()

        do {
            _ = try NIP44v3.decrypt(seckey: seckey, pubkey: pubkey, context: ctx, ciphertext: tamperedB64)
            XCTFail("decrypt should have rejected tampered embedded scope")
        } catch let e as NIP44v3.Error {
            XCTAssertEqual(e, .decryptionFailed,
                           "tampered embedded scope should surface as .decryptionFailed")
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }

    // MARK: - Helpers

    private static func hex(_ s: String) throws -> Data {
        guard let d = Data(hexString: s) else {
            throw NSError(domain: "NIP44v3Tests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "bad hex: \(s.prefix(40))"])
        }
        return d
    }

    /// Derive the BIP-340 x-only pubkey for a 32-byte secret key.
    /// JSON vectors give us `secret2` rather than the pubkey directly;
    /// the public API takes pubkey, so we derive at test time.
    private static func pubkey(forSecret seckeyHex: String) throws -> Data {
        let seckey = try hex(seckeyHex)
        let priv = try P256K.Schnorr.PrivateKey(dataRepresentation: seckey)
        return Data(priv.xonly.bytes)
    }

    private static func sha256Hex(_ d: Data) -> String {
        let h = CryptoKit.SHA256.hash(data: d)
        return h.map { String(format: "%02x", $0) }.joined()
    }
}
