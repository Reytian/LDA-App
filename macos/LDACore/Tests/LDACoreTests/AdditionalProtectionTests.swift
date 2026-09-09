import XCTest
@testable import LDACore

final class AdditionalProtectionTests: XCTestCase {
    func testAddedTermReachesWordBodyAndHeaderAndChangedReviewTextIsRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("fictional.docx")
        try DocxFixtureSupport.write(paragraphs: [[.bold("Quasar"), .plain(" approved this.")]], header: [[.plain("Quasar confidential")]], to: input)
        let text = try LDAService.localReviewText(input: input)
        let result = try LDAService.anonymize(input: input, outputDir: root.appendingPathComponent("out"), protection: .passphrase("fixture"), createdAtISO8601: "2026-09-08T00:00:00Z", additionalPatterns: [CustomPattern(text: "Quasar")], expectedReviewDigest: AdditionalProtection.textDigest(text))
        for part in ["word/document.xml", "word/header1.xml"] {
            XCTAssertFalse(try DocxFixtureSupport.part(part, in: result.redactedFileURL).contains("Quasar"))
        }
        XCTAssertThrowsError(try LDAService.anonymize(input: input, outputDir: root.appendingPathComponent("refused"), protection: .passphrase("fixture"), createdAtISO8601: "2026-09-08T00:00:00Z", additionalPatterns: [CustomPattern(text: "Quasar")], expectedReviewDigest: AdditionalProtection.textDigest("Different text")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("refused/fictional_redacted.docx").path))
    }
    func testSelectionInsideFindingCannotShrinkProtection() {
        let text = "Fictional Cedar Labs"
        let auto = Span(start: 0, end: text.utf16.count, type: .company, text: text, source: .manual, confidence: 1, priority: 100)
        let result = AdditionalProtection.merge(text: text, detected: [auto], patterns: [CustomPattern(text: "Cedar", type: .person)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.text, text)
    }

    func testPartialOverlapProtectsTheUnionAndRepeats() {
        let text = "Alpha Beta Gamma; Beta Gamma"
        let auto = Span(start: 0, end: 10, type: .company, text: "Alpha Beta", source: .manual, confidence: 1, priority: 100)
        let result = AdditionalProtection.merge(text: text, detected: [auto], patterns: [CustomPattern(text: "Beta Gamma")])
        XCTAssertEqual(result.map(\.text), ["Alpha Beta Gamma", "Beta Gamma"])
    }

    func testManualTermRoundTripsAlongsideAutomaticPII() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("fictional.txt")
        let original = "Project Quasar belongs to Quasar. Contact demo@example.com."
        try Data(original.utf8).write(to: input)
        let result = try LDAService.anonymize(input: input, outputDir: root.appendingPathComponent("out"), protection: .passphrase("fictional-test-key"), createdAtISO8601: "2026-09-08T00:00:00Z", additionalPatterns: [CustomPattern(text: "Quasar")])
        let safe = try String(contentsOf: result.redactedFileURL)
        XCTAssertFalse(safe.contains("Quasar"))
        XCTAssertFalse(safe.contains("demo@example.com"))
        let mapping = try MappingStore.load(from: result.mappingFileURL, protection: .passphrase("fictional-test-key"))
        XCTAssertEqual(mapping.entries.values.filter { $0.value == "Quasar" }.count, 1)
        XCTAssertEqual(Restorer.restore(text: safe, mapping: mapping).text, original)
        XCTAssertEqual(result.entities.filter { $0.text == "Quasar" }.count, 2)
    }
}
