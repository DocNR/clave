import XCTest
@testable import Clave

/// Tests for `LightSigner.extractConnectMetadata` — the optional 4th
/// `connect` param that lets a bunker client describe itself (name/url/image),
/// mirroring the metadata a client already puts in a `nostrconnect://` URI.
final class LightSignerConnectMetadataTests: XCTestCase {

    /// Standard 3-param connect (no metadata) — today's behavior must be
    /// preserved: empty metadata, nameless connection.
    func testNoFourthParamYieldsEmpty() {
        let params = ["signerpub", "secret-xyz", "sign_event:1,nip44_encrypt"]
        let meta = LightSigner.extractConnectMetadata(params: params)
        XCTAssertNil(meta.name)
        XCTAssertNil(meta.url)
        XCTAssertNil(meta.imageURL)
    }

    /// Full metadata object parses all three fields. `image` maps to `imageURL`.
    func testFullMetadataParsed() {
        let json = #"{"name":"Jank","url":"https://jank.army","image":"https://jank.army/icon.png"}"#
        let params = ["signerpub", "secret-xyz", "", json]
        let meta = LightSigner.extractConnectMetadata(params: params)
        XCTAssertEqual(meta.name, "Jank")
        XCTAssertEqual(meta.url, "https://jank.army")
        XCTAssertEqual(meta.imageURL, "https://jank.army/icon.png")
    }

    /// A client may send a name without perms — empty perms string in slot 2,
    /// metadata still lands in slot 3.
    func testNameOnlyWithEmptyPerms() {
        let json = #"{"name":"Jank"}"#
        let params = ["signerpub", "secret-xyz", "", json]
        let meta = LightSigner.extractConnectMetadata(params: params)
        XCTAssertEqual(meta.name, "Jank")
        XCTAssertNil(meta.url)
        XCTAssertNil(meta.imageURL)
    }

    /// Empty 4th param string degrades to empty, not a crash.
    func testEmptyFourthParam() {
        let params = ["signerpub", "secret-xyz", "", ""]
        let meta = LightSigner.extractConnectMetadata(params: params)
        XCTAssertNil(meta.name)
        XCTAssertNil(meta.url)
        XCTAssertNil(meta.imageURL)
    }

    /// Malformed JSON in the 4th param degrades to empty rather than throwing.
    func testMalformedJSONDegradesToEmpty() {
        let params = ["signerpub", "secret-xyz", "", "{not json"]
        let meta = LightSigner.extractConnectMetadata(params: params)
        XCTAssertNil(meta.name)
        XCTAssertNil(meta.url)
        XCTAssertNil(meta.imageURL)
    }

    /// Empty-string values inside the object are treated as absent so the UI
    /// falls back to its default label rather than showing a blank name.
    func testEmptyStringValuesTreatedAsNil() {
        let json = #"{"name":"","url":"","image":""}"#
        let params = ["signerpub", "secret-xyz", "", json]
        let meta = LightSigner.extractConnectMetadata(params: params)
        XCTAssertNil(meta.name)
        XCTAssertNil(meta.url)
        XCTAssertNil(meta.imageURL)
    }

    /// Non-string JSON values (e.g. a numeric name) are ignored rather than
    /// coerced — guards against odd client encodings.
    func testNonStringValuesIgnored() {
        let json = #"{"name":123,"url":true}"#
        let params = ["signerpub", "secret-xyz", "", json]
        let meta = LightSigner.extractConnectMetadata(params: params)
        XCTAssertNil(meta.name)
        XCTAssertNil(meta.url)
    }

    /// Extra unknown keys are ignored; known keys still parse. Keeps the
    /// parser forward-compatible with future metadata fields.
    func testExtraKeysIgnored() {
        let json = #"{"name":"Jank","perms":"sign_event","future_field":"x"}"#
        let params = ["signerpub", "secret-xyz", "", json]
        let meta = LightSigner.extractConnectMetadata(params: params)
        XCTAssertEqual(meta.name, "Jank")
        XCTAssertNil(meta.url)
        XCTAssertNil(meta.imageURL)
    }
}
