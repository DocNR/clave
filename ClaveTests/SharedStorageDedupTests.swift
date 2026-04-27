import XCTest
@testable import Clave

final class SharedStorageDedupTests: XCTestCase {
    private let testKey = "test.processedEventIDs"

    override func setUp() {
        super.setUp()
        SharedConstants.sharedDefaults.removeObject(forKey: testKey)
        SharedStorage._setProcessedEventIDsKeyForTesting(testKey)
    }

    override func tearDown() {
        SharedConstants.sharedDefaults.removeObject(forKey: testKey)
        SharedStorage._resetProcessedEventIDsKeyForTesting()
        super.tearDown()
    }

    func test_firstSeenEvent_returnsMarkedNew() {
        let now = Date().timeIntervalSince1970
        let result = SharedStorage.markEventProcessed(eventId: "abc", createdAt: now)
        XCTAssertEqual(result, .markedNew)
    }

    func test_repeatedEvent_returnsAlreadyProcessed() {
        let now = Date().timeIntervalSince1970
        _ = SharedStorage.markEventProcessed(eventId: "abc", createdAt: now)
        let result = SharedStorage.markEventProcessed(eventId: "abc", createdAt: now)
        XCTAssertEqual(result, .alreadyProcessed)
    }

    func test_ringBufferEvictsOldestPastCap() {
        // Cap is 200. Insert 201 unique ids with fresh timestamps so age-eviction
        // doesn't kick in. The first should be evicted by cap.
        let now = Date().timeIntervalSince1970
        for i in 0..<201 {
            _ = SharedStorage.markEventProcessed(eventId: "id\(i)", createdAt: now)
        }
        // The very first id ("id0") should now NOT be considered processed.
        let result = SharedStorage.markEventProcessed(eventId: "id0", createdAt: now)
        XCTAssertEqual(result, .markedNew, "id0 should have been evicted past the 200-entry cap")
    }

    func test_oldEntries_evictedByAge() {
        let now = Date().timeIntervalSince1970
        let oldTs = now - 120  // 120s ago, beyond 60s window
        _ = SharedStorage.markEventProcessed(eventId: "old", createdAt: oldTs)

        // Inserting a fresh event triggers age-based eviction sweep.
        _ = SharedStorage.markEventProcessed(eventId: "fresh", createdAt: now)

        // "old" should now be evicted by age, so re-inserting returns markedNew.
        let result = SharedStorage.markEventProcessed(eventId: "old", createdAt: oldTs)
        XCTAssertEqual(result, .markedNew, "old entries should age out after 60s")
    }

    func test_concurrentMarks_serializeWithinProcess() async {
        // 100 concurrent marks of the same id from the same process.
        // Lossy semantics across processes are acceptable (see spec), but
        // within one process serialization must hold.
        let id = "concurrent"
        let createdAt = Date().timeIntervalSince1970
        let results: [SharedStorage.ProcessedStatus] = await withTaskGroup(
            of: SharedStorage.ProcessedStatus.self,
            returning: [SharedStorage.ProcessedStatus].self
        ) { group in
            for _ in 0..<100 {
                group.addTask {
                    SharedStorage.markEventProcessed(eventId: id, createdAt: createdAt)
                }
            }
            var collected: [SharedStorage.ProcessedStatus] = []
            for await r in group { collected.append(r) }
            return collected
        }
        let newCount = results.filter { $0 == .markedNew }.count
        XCTAssertEqual(newCount, 1, "exactly one task should see markedNew within one process")
    }
}
