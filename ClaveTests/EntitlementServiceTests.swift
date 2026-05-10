import XCTest
@testable import Clave

final class EntitlementServiceTests: XCTestCase {

    // ---------- helpers ----------

    /// Each test gets its own UserDefaults suite so cache state doesn't leak.
    private func makeDefaults(file: StaticString = #file, line: UInt = #line) -> UserDefaults {
        let suiteName = "EntitlementServiceTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("UserDefaults suite init failed", file: file, line: line)
            return UserDefaults.standard
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeService(
        defaults: UserDefaults? = nil,
        cacheTTL: TimeInterval = EntitlementService.defaultCacheTTL,
        now: @Sendable @escaping () -> Date = { Date() },
        sessionConfigurator: ((URLSessionConfiguration) -> Void)? = nil
    ) -> EntitlementService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        sessionConfigurator?(config)
        let session = URLSession(configuration: config)
        return EntitlementService(
            proxyURL: URL(string: "https://proxy-test.clave.casa")!,
            session: session,
            userDefaults: defaults ?? makeDefaults(),
            cacheTTL: cacheTTL,
            now: now
        )
    }

    private let pubkeyA = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private let pubkeyB = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    // ---------- Entitlement decoder ----------

    func test_entitlement_decodesPremiumResponse() throws {
        let json = """
        {
            "pubkey": "\(pubkeyA)",
            "tier": "premium",
            "max_accounts": 10,
            "max_clients": 30,
            "granted_at": 1714000000,
            "expires_at": null,
            "granted_by": "admin:cli"
        }
        """.data(using: .utf8)!
        let ent = try JSONDecoder().decode(Entitlement.self, from: json)
        XCTAssertEqual(ent.pubkey, pubkeyA)
        XCTAssertEqual(ent.tier, .premium)
        XCTAssertEqual(ent.maxAccounts, 10)
        XCTAssertEqual(ent.maxClients, 30)
        XCTAssertEqual(ent.grantedAt, 1714000000)
        XCTAssertNil(ent.expiresAt)
        XCTAssertEqual(ent.grantedBy, "admin:cli")
    }

    func test_entitlement_decodesFreeResponseWithoutOptionalFields() throws {
        // Server returns just {pubkey, tier, max_accounts, max_clients} when
        // there's no entitlement record (everyone defaults to free).
        let json = """
        {"pubkey":"\(pubkeyA)","tier":"free","max_accounts":4,"max_clients":5}
        """.data(using: .utf8)!
        let ent = try JSONDecoder().decode(Entitlement.self, from: json)
        XCTAssertEqual(ent.tier, .free)
        XCTAssertNil(ent.grantedAt)
        XCTAssertNil(ent.grantedBy)
    }

    func test_entitlement_ignoresUnknownFutureFields() throws {
        // Forward-compat: Phase 2 may add fields like "lightning_invoice_id".
        // Older iOS must not break.
        let json = """
        {
            "pubkey": "\(pubkeyA)",
            "tier": "premium",
            "max_accounts": 10,
            "max_clients": 30,
            "lightning_invoice_id": "lnbc1...",
            "billing_cycle": "lifetime",
            "future_field": {"nested": "object"}
        }
        """.data(using: .utf8)!
        let ent = try JSONDecoder().decode(Entitlement.self, from: json)
        XCTAssertEqual(ent.tier, .premium)
    }

    func test_entitlement_effectiveTier_lifetime() {
        let ent = Entitlement(pubkey: pubkeyA, tier: .premium, maxAccounts: 10, maxClients: 30,
                              grantedAt: 1700000000, expiresAt: nil)
        XCTAssertEqual(ent.effectiveTier(), .premium)
    }

    func test_entitlement_effectiveTier_unexpired() {
        let future = Date().timeIntervalSince1970 + 86400
        let ent = Entitlement(pubkey: pubkeyA, tier: .premium, maxAccounts: 10, maxClients: 30,
                              expiresAt: future)
        XCTAssertEqual(ent.effectiveTier(), .premium)
    }

    func test_entitlement_effectiveTier_expiredPremiumDowngrades() {
        // expires_at is in the past → effectiveTier reads as free without
        // mutating the stored record.
        let past = Date().timeIntervalSince1970 - 86400
        let ent = Entitlement(pubkey: pubkeyA, tier: .premium, maxAccounts: 10, maxClients: 30,
                              expiresAt: past)
        XCTAssertEqual(ent.effectiveTier(), .free)
        XCTAssertEqual(ent.tier, .premium, "stored tier preserved")
    }

    func test_entitlement_effectiveTier_freeStaysFree() {
        let ent = Entitlement(pubkey: pubkeyA, tier: .free, maxAccounts: 4, maxClients: 5)
        XCTAssertEqual(ent.effectiveTier(), .free)
    }

    // ---------- cache layer ----------

    func test_cachedTier_returnsNilWhenNoEntry() {
        let svc = makeService()
        XCTAssertNil(svc.cachedTier(for: pubkeyA))
    }

    func test_cachedTier_returnsTierAfterSave() {
        let svc = makeService()
        let ent = Entitlement(pubkey: pubkeyA, tier: .premium, maxAccounts: 10, maxClients: 30)
        svc.saveCache(ent, for: pubkeyA)
        XCTAssertEqual(svc.cachedTier(for: pubkeyA), .premium)
    }

    func test_cachedTier_returnsNilWhenTTLExceeded() {
        // Pin "now" to a later time so the existing cache (saved at "real" now)
        // appears to be older than the 1-second TTL.
        let defaults = makeDefaults()
        let svc1 = makeService(defaults: defaults, cacheTTL: 1)
        let ent = Entitlement(pubkey: pubkeyA, tier: .premium, maxAccounts: 10, maxClients: 30)
        svc1.saveCache(ent, for: pubkeyA)

        let later = Date(timeIntervalSinceNow: 60) // 60s later — well past 1s TTL
        let svc2 = makeService(defaults: defaults, cacheTTL: 1, now: { later })
        XCTAssertNil(svc2.cachedTier(for: pubkeyA), "expired cache reads as nil")
    }

    func test_cachedTier_invalidatesOnVersionMismatch() {
        // Manually inject a CachedEntitlement with a stale version number.
        let defaults = makeDefaults()
        let svc = makeService(defaults: defaults)
        let payload: [String: Any] = [
            "version": 0,  // old
            "entitlement": [
                "pubkey": pubkeyA,
                "tier": "premium",
                "max_accounts": 10,
                "max_clients": 30,
            ],
            "cachedAt": Date().timeIntervalSince1970
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        defaults.set(data, forKey: svc.cacheKey(for: pubkeyA))
        XCTAssertNil(svc.cachedTier(for: pubkeyA))
    }

    func test_cachedTier_downgradesExpiredPremiumOnRead() {
        // Saved with future expiry; read after expiry passes — should downgrade.
        let defaults = makeDefaults()
        let now1 = Date(timeIntervalSince1970: 1_700_000_000)
        let expiry = Date(timeIntervalSince1970: 1_700_000_100)  // 100s after now1
        let now2 = Date(timeIntervalSince1970: 1_700_000_200)    // 100s after expiry

        let svc1 = makeService(defaults: defaults, now: { now1 })
        let ent = Entitlement(pubkey: pubkeyA, tier: .premium, maxAccounts: 10, maxClients: 30,
                              expiresAt: expiry.timeIntervalSince1970)
        svc1.saveCache(ent, for: pubkeyA)

        let svc2 = makeService(defaults: defaults, now: { now2 })
        XCTAssertEqual(svc2.cachedTier(for: pubkeyA), .free,
                       "expired premium reads as free even when cache is fresh")
    }

    func test_clearCache_removesEntry() {
        let svc = makeService()
        let ent = Entitlement(pubkey: pubkeyA, tier: .premium, maxAccounts: 10, maxClients: 30)
        svc.saveCache(ent, for: pubkeyA)
        XCTAssertEqual(svc.cachedTier(for: pubkeyA), .premium)
        svc.clearCache(for: pubkeyA)
        XCTAssertNil(svc.cachedTier(for: pubkeyA))
    }

    func test_cacheKey_isCaseInsensitive() {
        let svc = makeService()
        XCTAssertEqual(svc.cacheKey(for: pubkeyA), svc.cacheKey(for: pubkeyA.uppercased()))
    }

    // ---------- effectiveTier composition ----------

    func test_effectiveTier_anyPremiumPubkeyElevatesDevice() {
        let svc = makeService()
        svc.saveCache(Entitlement(pubkey: pubkeyA, tier: .free, maxAccounts: 4, maxClients: 5), for: pubkeyA)
        svc.saveCache(Entitlement(pubkey: pubkeyB, tier: .premium, maxAccounts: 10, maxClients: 30), for: pubkeyB)
        XCTAssertEqual(svc.effectiveTier(for: [pubkeyA, pubkeyB]), .premium)
    }

    func test_effectiveTier_allFreeReturnsFree() {
        let svc = makeService()
        svc.saveCache(Entitlement(pubkey: pubkeyA, tier: .free, maxAccounts: 4, maxClients: 5), for: pubkeyA)
        svc.saveCache(Entitlement(pubkey: pubkeyB, tier: .free, maxAccounts: 4, maxClients: 5), for: pubkeyB)
        XCTAssertEqual(svc.effectiveTier(for: [pubkeyA, pubkeyB]), .free)
    }

    func test_effectiveTier_emptyPubkeysReturnsFree() {
        let svc = makeService()
        XCTAssertEqual(svc.effectiveTier(for: []), .free)
    }

    func test_effectiveTier_uncachedPubkeysIgnored() {
        // Two pubkeys; only one has cache. Other contributes nothing.
        let svc = makeService()
        svc.saveCache(Entitlement(pubkey: pubkeyA, tier: .premium, maxAccounts: 10, maxClients: 30), for: pubkeyA)
        XCTAssertEqual(svc.effectiveTier(for: [pubkeyA, pubkeyB]), .premium)
    }

    // ---------- network refresh ----------

    func test_refresh_storesEntitlementOnSuccess() async {
        let defaults = makeDefaults()
        let svc = makeService(defaults: defaults)
        MockURLProtocol.requestHandler = { req in
            let body = """
            {"pubkey":"\(self.pubkeyA)","tier":"premium","max_accounts":10,"max_clients":30,"granted_at":1714000000,"expires_at":null,"granted_by":"admin:cli"}
            """.data(using: .utf8)!
            return (Self.httpResponse(req, status: 200), body)
        }
        let result = await svc.refresh(pubkey: pubkeyA, signer: Self.constantSigner)
        if case .ok(let ent) = result {
            XCTAssertEqual(ent.tier, .premium)
            XCTAssertEqual(svc.cachedTier(for: pubkeyA), .premium)
        } else {
            XCTFail("expected .ok, got \(result)")
        }
    }

    func test_refresh_passesXClaveAuthHeader() async {
        let svc = makeService()
        var capturedAuth: String?
        MockURLProtocol.requestHandler = { req in
            capturedAuth = req.value(forHTTPHeaderField: "X-Clave-Auth")
            let body = """
            {"pubkey":"\(self.pubkeyA)","tier":"free","max_accounts":4,"max_clients":5}
            """.data(using: .utf8)!
            return (Self.httpResponse(req, status: 200), body)
        }
        _ = await svc.refresh(pubkey: pubkeyA, signer: { _, _ in "Nostr base64-mock" })
        XCTAssertEqual(capturedAuth, "Nostr base64-mock", "X-Clave-Auth header is set from signer return")
    }

    func test_refresh_returnsHttpErrorOnNon200() async {
        let svc = makeService()
        MockURLProtocol.requestHandler = { req in
            return (Self.httpResponse(req, status: 401), Data("{\"error\":\"bad sig\"}".utf8))
        }
        let result = await svc.refresh(pubkey: pubkeyA, signer: Self.constantSigner)
        if case .httpError(let status, _) = result {
            XCTAssertEqual(status, 401)
        } else {
            XCTFail("expected .httpError, got \(result)")
        }
        XCTAssertNil(svc.cachedTier(for: pubkeyA), "cache untouched on failure")
    }

    func test_refresh_returnsSignerErrorWhenSignerThrows() async {
        let svc = makeService()
        struct SignerError: Error {}
        let result = await svc.refresh(pubkey: pubkeyA, signer: { _, _ in throw SignerError() })
        if case .signerError = result { /* ok */ } else { XCTFail("expected .signerError, got \(result)") }
    }

    func test_refresh_returnsDecodeErrorOnGarbageJson() async {
        let svc = makeService()
        MockURLProtocol.requestHandler = { req in
            return (Self.httpResponse(req, status: 200), Data("not json".utf8))
        }
        let result = await svc.refresh(pubkey: pubkeyA, signer: Self.constantSigner)
        if case .decodeError = result { /* ok */ } else { XCTFail("expected .decodeError, got \(result)") }
    }

    func test_refresh_rejectsPubkeyMismatch() async {
        // Server returns a different pubkey than we asked about — signal of
        // misconfigured/malicious proxy. Reject without caching.
        let svc = makeService()
        MockURLProtocol.requestHandler = { req in
            let body = """
            {"pubkey":"\(self.pubkeyB)","tier":"premium","max_accounts":10,"max_clients":30}
            """.data(using: .utf8)!
            return (Self.httpResponse(req, status: 200), body)
        }
        let result = await svc.refresh(pubkey: pubkeyA, signer: Self.constantSigner)
        if case .decodeError(let msg) = result {
            XCTAssertTrue(msg.contains("pubkey mismatch"), "got \(msg)")
        } else {
            XCTFail("expected .decodeError, got \(result)")
        }
        XCTAssertNil(svc.cachedTier(for: pubkeyA), "cache not poisoned")
    }

    // ---------- helpers (static) ----------

    static let constantSigner: EntitlementSigner = { _, _ in "Nostr mock-base64" }

    static func httpResponse(_ req: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

// ---------- URLSession mock ----------

/// `URLProtocol` subclass for stubbing `URLSession` responses in tests.
/// Tests set `MockURLProtocol.requestHandler` to control the response.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
