import XCTest
@testable import Clave

final class LogExporterFormattingTests: XCTestCase {

    func testFormatEntriesProducesIsoTimestampCategoryMessage() {
        let entries = [
            LogExporter.Entry(
                date: Date(timeIntervalSince1970: 1_776_600_000),
                category: "relay",
                message: "Connected to wss://relay.powr.build"
            ),
            LogExporter.Entry(
                date: Date(timeIntervalSince1970: 1_776_600_001),
                category: "signer",
                message: "Method: sign_event"
            )
        ]
        let output = LogExporter.format(entries: entries)
        let lines = output.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("[relay]"))
        XCTAssertTrue(lines[0].contains("Connected to wss://relay.powr.build"))
        XCTAssertTrue(lines[1].contains("[signer]"))
        XCTAssertTrue(lines[1].contains("Method: sign_event"))
    }

    func testFormatEntriesWithCategoryFilter() {
        let entries = [
            LogExporter.Entry(date: Date(), category: "relay", message: "A"),
            LogExporter.Entry(date: Date(), category: "signer", message: "B"),
            LogExporter.Entry(date: Date(), category: "storage", message: "C")
        ]
        let output = LogExporter.format(entries: entries, categories: ["signer"])
        XCTAssertFalse(output.contains("A"))
        XCTAssertTrue(output.contains("B"))
        XCTAssertFalse(output.contains("C"))
    }

    func testFormatEntriesEmptyWhenNoMatches() {
        let entries = [
            LogExporter.Entry(date: Date(), category: "relay", message: "A")
        ]
        let output = LogExporter.format(entries: entries, categories: ["signer"])
        XCTAssertEqual(output, "")
    }
}
