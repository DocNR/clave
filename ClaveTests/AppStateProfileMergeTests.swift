import XCTest
@testable import Clave

/// Tests for `AppState.mergeKind0` — the cross-relay selection step that
/// picks the latest kind:0 by max(`created_at`).
///
/// Regression: prior to this fix, the merge picked "first response with
/// picture" instead of the highest `created_at`. When the user's primary
/// low-latency relay carried a stale-but-valid kind:0, it won the race
/// against newer events on other relays — surfacing as "I edited my profile
/// on clave.casa but Clave iOS still shows the old fields after pull-to-
/// refresh." See `AppState.swift` `fetchProfile(for:)` for the call site.
final class AppStateProfileMergeTests: XCTestCase {

    private func makeFetched(
        name: String,
        createdAt: Int64,
        picture: String? = "https://example.com/avatar.jpg"
    ) -> AppState.FetchedKind0 {
        AppState.FetchedKind0(
            profile: CachedProfile(
                displayName: name,
                name: name,
                pictureURL: picture,
                fetchedAt: 0
            ),
            createdAt: createdAt
        )
    }

    func testMergeKind0_picksHighestCreatedAt() {
        let a = makeFetched(name: "A", createdAt: 100)
        let b = makeFetched(name: "B", createdAt: 200)
        let c = makeFetched(name: "C", createdAt: 150)

        let result = AppState.mergeKind0([a, b, c])

        XCTAssertEqual(result?.profile.name, "B")
        XCTAssertEqual(result?.createdAt, 200)
    }

    /// Regression test for the bug this commit fixes. Both events have a
    /// picture; the previous "first-with-picture" implementation would
    /// return whichever arrived first (typically the stale one from the
    /// user's primary relay). The fix must pick the higher `created_at`
    /// regardless of arrival order.
    func testMergeKind0_picksLatestEvenWhenFirstHasPicture() {
        let stale = makeFetched(
            name: "stale",
            createdAt: 100,
            picture: "https://example.com/old.jpg"
        )
        let fresh = makeFetched(
            name: "fresh",
            createdAt: 200,
            picture: "https://example.com/new.jpg"
        )

        let result = AppState.mergeKind0([stale, fresh])

        XCTAssertEqual(result?.profile.name, "fresh")
        XCTAssertEqual(result?.createdAt, 200)
    }

    func testMergeKind0_handlesAllNil() {
        let result = AppState.mergeKind0([nil, nil, nil])
        XCTAssertNil(result)
    }

    func testMergeKind0_handlesSomeNil() {
        let valid = makeFetched(name: "A", createdAt: 100)
        let result = AppState.mergeKind0([nil, valid, nil])
        XCTAssertEqual(result?.profile.name, "A")
        XCTAssertEqual(result?.createdAt, 100)
    }

    /// Order-independence: the merge must not depend on the iteration
    /// order of relay responses (which is a TaskGroup race in production).
    func testMergeKind0_isOrderIndependent() {
        let stale = makeFetched(name: "stale", createdAt: 100)
        let fresh = makeFetched(name: "fresh", createdAt: 200)

        let resultStaleFirst = AppState.mergeKind0([stale, fresh])
        let resultFreshFirst = AppState.mergeKind0([fresh, stale])

        XCTAssertEqual(resultStaleFirst?.profile.name, "fresh")
        XCTAssertEqual(resultFreshFirst?.profile.name, "fresh")
    }
}
