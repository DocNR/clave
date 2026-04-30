import XCTest
@testable import Clave

final class ActivitySummaryTests: XCTestCase {

    // MARK: - Kind 1 (note)

    func testKind1NewNote() {
        let summary = ActivitySummary.signedSummary(kind: 1, tags: [])
        XCTAssertEqual(summary, "New note")
    }

    func testKind1WithHashtag() {
        let summary = ActivitySummary.signedSummary(kind: 1, tags: [["t", "nostr"]])
        XCTAssertEqual(summary, "New note · #nostr")
    }

    func testKind1Reply() {
        let summary = ActivitySummary.signedSummary(
            kind: 1,
            tags: [["e", "abc123def456789012345678901234567890123456789012345678901234abcd"]]
        )
        XCTAssertEqual(summary, "Reply to e:abc123de…abcd")
    }

    func testKind1ReplyWithMention() {
        let summary = ActivitySummary.signedSummary(
            kind: 1,
            tags: [
                ["e", "abc123def456789012345678901234567890123456789012345678901234abcd"],
                ["p", "alice5678901234567890123456789012345678901234567890123456789aaaa"]
            ]
        )
        XCTAssertEqual(summary, "Reply to e:abc123de…abcd · @alice567…aaaa")
    }

    func testKind1MultipleMentionsCounted() {
        let tags: [[String]] = [
            ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"],
            ["p", "bob5678901234567890123456789012345678901234567890123456789012bbbb"],
            ["p", "carol6789012345678901234567890123456789012345678901234567890cccc"]
        ]
        let summary = ActivitySummary.signedSummary(kind: 1, tags: tags)
        XCTAssertEqual(summary, "New note · @alice567…aaaa +2")
    }

    // MARK: - Kind 0 (profile)

    func testKind0() {
        let summary = ActivitySummary.signedSummary(kind: 0, tags: [])
        XCTAssertEqual(summary, "Updated profile")
    }

    // MARK: - Kind 3 (contacts) — diff handling

    func testKind3FirstEverNoSnapshot() {
        let summary = ActivitySummary.signedSummary(
            kind: 3,
            tags: [
                ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"],
                ["p", "bob5678901234567890123456789012345678901234567890123456789012bbbb"]
            ],
            previousContactSet: nil
        )
        XCTAssertEqual(summary, "Set contact list (2 follows)")
    }

    func testKind3SingleAdd() {
        let prior: Set<String> = [
            "alice56789012345678901234567890123456789012345678901234567890aaaa"
        ]
        let summary = ActivitySummary.signedSummary(
            kind: 3,
            tags: [
                ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"],
                ["p", "bob5678901234567890123456789012345678901234567890123456789012bbbb"]
            ],
            previousContactSet: prior
        )
        XCTAssertEqual(summary, "Followed @bob56789…bbbb")
    }

    func testKind3SingleRemove() {
        let prior: Set<String> = [
            "alice56789012345678901234567890123456789012345678901234567890aaaa",
            "bob5678901234567890123456789012345678901234567890123456789012bbbb"
        ]
        let summary = ActivitySummary.signedSummary(
            kind: 3,
            tags: [
                ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"]
            ],
            previousContactSet: prior
        )
        XCTAssertEqual(summary, "Unfollowed @bob56789…bbbb")
    }

    func testKind3SmallMixedDiff() {
        let prior: Set<String> = [
            "alice56789012345678901234567890123456789012345678901234567890aaaa",
            "bob5678901234567890123456789012345678901234567890123456789012bbbb"
        ]
        let summary = ActivitySummary.signedSummary(
            kind: 3,
            tags: [
                ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"],
                ["p", "carol6789012345678901234567890123456789012345678901234567890cccc"]
            ],
            previousContactSet: prior
        )
        XCTAssertEqual(summary, "Contacts +1 / -1")
    }

    func testKind3LargeDiff() {
        var prior: Set<String> = []
        for i in 0..<50 {
            prior.insert(String(format: "%064d", i))
        }
        var newTags: [[String]] = []
        for i in 25..<75 {
            newTags.append(["p", String(format: "%064d", i)])
        }
        let summary = ActivitySummary.signedSummary(
            kind: 3,
            tags: newTags,
            previousContactSet: prior
        )
        XCTAssertEqual(summary, "Contacts +25 / -25")
    }

    func testKind3OverflowSkipsDiff() {
        var tags: [[String]] = []
        for i in 0..<2001 {
            tags.append(["p", String(format: "%064d", i)])
        }
        let summary = ActivitySummary.signedSummary(
            kind: 3,
            tags: tags,
            previousContactSet: ["dummy56789012345678901234567890123456789012345678901234567890dddd"]
        )
        XCTAssertEqual(summary, "Updated contact list (2001 follows)")
    }

    func testKind3UnchangedSet() {
        let prior: Set<String> = [
            "alice56789012345678901234567890123456789012345678901234567890aaaa"
        ]
        let summary = ActivitySummary.signedSummary(
            kind: 3,
            tags: [
                ["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"]
            ],
            previousContactSet: prior
        )
        XCTAssertEqual(summary, "Republished contact list (1 follow)")
    }

    // MARK: - DMs

    func testKind4DM() {
        let summary = ActivitySummary.signedSummary(
            kind: 4,
            tags: [["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"]]
        )
        XCTAssertEqual(summary, "DM to @alice567…aaaa")
    }

    func testKind14SealedDM() {
        let summary = ActivitySummary.signedSummary(
            kind: 14,
            tags: [["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"]]
        )
        XCTAssertEqual(summary, "DM to @alice567…aaaa")
    }

    func testKind1059GiftWrap() {
        let summary = ActivitySummary.signedSummary(
            kind: 1059,
            tags: [["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"]]
        )
        XCTAssertEqual(summary, "DM to @alice567…aaaa")
    }

    // MARK: - Repost / Reaction

    func testKind6Repost() {
        let summary = ActivitySummary.signedSummary(
            kind: 6,
            tags: [["e", "abc123def456789012345678901234567890123456789012345678901234abcd"]]
        )
        XCTAssertEqual(summary, "Reposted e:abc123de…abcd")
    }

    func testKind7Reaction() {
        let summary = ActivitySummary.signedSummary(
            kind: 7,
            tags: [["e", "abc123def456789012345678901234567890123456789012345678901234abcd"]]
        )
        XCTAssertEqual(summary, "Reacted to e:abc123de…abcd")
    }

    // MARK: - Zap request / Relay list / Relay auth

    func testKind9734ZapRequest() {
        let summary = ActivitySummary.signedSummary(
            kind: 9734,
            tags: [["p", "alice56789012345678901234567890123456789012345678901234567890aaaa"]]
        )
        XCTAssertEqual(summary, "Zap request to @alice567…aaaa")
    }

    func testKind10002RelayList() {
        let summary = ActivitySummary.signedSummary(
            kind: 10002,
            tags: [
                ["r", "wss://relay.damus.io"],
                ["r", "wss://relay.snort.social", "read"],
                ["r", "wss://nos.lol"]
            ]
        )
        XCTAssertEqual(summary, "Relay list (3 relays)")
    }

    func testKind22242RelayAuth() {
        let summary = ActivitySummary.signedSummary(
            kind: 22242,
            tags: [
                ["relay", "wss://relay.damus.io"],
                ["challenge", "abc123"]
            ]
        )
        XCTAssertEqual(summary, "Authed to wss://relay.damus.io")
    }

    func testKind22242NoRelay() {
        let summary = ActivitySummary.signedSummary(
            kind: 22242,
            tags: [["challenge", "abc123"]]
        )
        XCTAssertEqual(summary, "Relay auth")
    }

    // MARK: - Long-form / app data

    func testKind30023WithTitle() {
        let summary = ActivitySummary.signedSummary(
            kind: 30023,
            tags: [["title", "On Building Signers"]]
        )
        XCTAssertEqual(summary, "Article: \"On Building Signers\"")
    }

    func testKind30023TitleTruncation() {
        let longTitle = String(repeating: "x", count: 100)
        let summary = ActivitySummary.signedSummary(
            kind: 30023,
            tags: [["title", longTitle]]
        )
        XCTAssertNotNil(summary)
        XCTAssertLessThanOrEqual(summary!.count, 80)
        XCTAssertTrue(summary!.contains("…"))
    }

    func testKind30023NoTitle() {
        let summary = ActivitySummary.signedSummary(kind: 30023, tags: [])
        XCTAssertEqual(summary, "Article")
    }

    func testKind30078AppData() {
        let summary = ActivitySummary.signedSummary(
            kind: 30078,
            tags: [["d", "my-app-key"]]
        )
        XCTAssertEqual(summary, "App data (my-app-key)")
    }

    // MARK: - Fallback

    func testUnknownKind() {
        let summary = ActivitySummary.signedSummary(kind: 99999, tags: [])
        XCTAssertEqual(summary, "Kind 99999")
    }

    // MARK: - Length cap

    func testSummaryNeverExceedsCap() {
        let manyHashtags: [[String]] = (0..<20).map { ["t", "longhashtag\($0)"] }
        let summary = ActivitySummary.signedSummary(kind: 1, tags: manyHashtags)
        XCTAssertNotNil(summary)
        XCTAssertLessThanOrEqual(summary!.count, 120)
    }
}
