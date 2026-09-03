//
//  LDAServiceSpanFilterTests.swift
//  LDACoreTests
//
//  The review step at the engine level: a caller may exclude detected spans
//  from redaction, by type (everywhere: body, docx non-body parts, image
//  channel) or by a per-span body filter, before anything is tokenized. The
//  MCP surface builds its "redact everything except ..." arguments on these
//  two seams, and it also relies on the observation contract pinned here: the
//  body filter sees EVERY detected body span, in order, including the spans a
//  type exclusion is about to drop.
//
//  Deterministic-only detection (no GGUF model), hermetic temp fixtures, and
//  passphrase-protected sidecars, so nothing here touches the Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LDAServiceSpanFilterTests: XCTestCase {

    private static let createdAt = "2026-09-02T00:00:00Z"
    private static let firstEmail = "alpha.party@example.com"
    private static let secondEmail = "beta.party@example.com"
    private static let bodyDate = "2024-01-15"
    private static let headerDate = "2023-12-31"
    private static let repeatedPhone = "13912345678"
    private static let otherPhone = "13800002222"
    private let protection = MappingProtection.passphrase("span-filter-pw")

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDAServiceSpanFilterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func writeText(_ text: String, named name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func outputDir(_ name: String) -> URL {
        workDir.appendingPathComponent(name, isDirectory: true)
    }

    private func loadMapping(_ result: AnonymizeResult) throws -> Mapping {
        try MappingStore.load(from: result.mappingFileURL, protection: protection)
    }

    // MARK: - Per-span body filter

    func testSpanFilterDropsBodySpansBeforeTokenization() throws {
        let text = "Reach \(Self.firstEmail) or \(Self.secondEmail) by \(Self.bodyDate)."
        let input = try writeText(text, named: "letter.txt")
        let excluded = (text as NSString).range(of: Self.firstEmail)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir("out"),
            protection: protection,
            createdAtISO8601: Self.createdAt,
            spanFilter: { span in
                !(span.start == excluded.location && span.end == excluded.location + excluded.length)
            }
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertTrue(redacted.contains(Self.firstEmail), "the excluded value stays visible")
        XCTAssertFalse(redacted.contains(Self.secondEmail), "every other value is still redacted")
        XCTAssertTrue(redacted.contains("{EMAIL_1}"))
        XCTAssertFalse(redacted.contains("{EMAIL_2}"), "the excluded span never minted a token")
        XCTAssertTrue(redacted.contains("{DATE_1}"))

        XCTAssertEqual(result.excludedEntityCount, 1)
        XCTAssertEqual(result.entities.count, 2)
        XCTAssertFalse(result.entities.contains { $0.text == Self.firstEmail })

        let mapping = try loadMapping(result)
        XCTAssertFalse(
            mapping.entries.values.contains { $0.value == Self.firstEmail },
            "an excluded value must not enter the mapping sidecar"
        )
    }

    /// The observation contract: the filter is consulted for every detected
    /// body span, in detection order, and a type exclusion does not hide the
    /// spans it drops from the filter. The MCP layer derives its detection
    /// fingerprint from exactly this stream.
    func testSpanFilterSeesEveryBodySpanInDetectionOrderIncludingExcludedTypes() throws {
        let text = "Reach \(Self.firstEmail) or \(Self.secondEmail) by \(Self.bodyDate)."
        let input = try writeText(text, named: "observed.txt")
        var seen: [Span] = []

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir("out"),
            protection: protection,
            createdAtISO8601: Self.createdAt,
            spanFilter: { span in
                seen.append(span)
                return true
            },
            excludedTypes: [.date]
        )

        let detected = try LDAService.detect(input: input)
        XCTAssertEqual(seen, detected, "the filter must see the full detection set, in order")
        XCTAssertTrue(seen.contains { $0.type == .date }, "type-excluded spans are still presented")
        XCTAssertFalse(result.entities.contains { $0.type == .date })
        XCTAssertEqual(result.excludedEntityCount, 1)
    }

    func testNoExclusionsLeavesTheResultUnchanged() throws {
        let text = "Reach \(Self.firstEmail) by \(Self.bodyDate)."
        let input = try writeText(text, named: "plain.txt")

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir("out"),
            protection: protection,
            createdAtISO8601: Self.createdAt
        )

        XCTAssertEqual(result.excludedEntityCount, 0)
        XCTAssertEqual(result.excludedValueCount, 0)
        XCTAssertEqual(result.entities.count, 2)
    }

    // MARK: - Excluding one occurrence excludes the value

    /// Excluding ONE detected occurrence must leave EVERY occurrence of that
    /// same value visible, on every channel. Anything less publishes the
    /// value and its own token in one document, and a reader who sees both
    /// can de-anonymize that token at every other site, including the ones a
    /// header or a comment carries.
    func testExcludingOneOccurrenceLeavesEveryOccurrenceOfThatValueVisible() throws {
        let input = workDir.appendingPathComponent("repeated.docx")
        try DocxFixtureSupport.write(
            paragraphs: [
                [.plain("Contact "), .bold(Self.firstEmail), .plain(" or \(Self.repeatedPhone).")],
                [.plain("Call \(Self.repeatedPhone) to confirm.")],
                [.plain("Backup line \(Self.repeatedPhone).")],
                [.plain("Fax \(Self.repeatedPhone) as well, or \(Self.otherPhone).")]
            ],
            header: [[.plain("Desk \(Self.repeatedPhone)")]],
            to: input
        )
        // The caller names exactly one occurrence: the FIRST one in the body.
        let firstOccurrenceExcluded = ExcludeFirstOccurrence(of: Self.repeatedPhone)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir("out"),
            protection: protection,
            createdAtISO8601: Self.createdAt,
            spanFilter: firstOccurrenceExcluded.keep
        )

        XCTAssertEqual(firstOccurrenceExcluded.matchCount, 4, "fixture: four body occurrences")
        let body = try DocxFixtureSupport.part(docxMainPartPath, in: result.redactedFileURL)
        XCTAssertEqual(
            body.components(separatedBy: Self.repeatedPhone).count - 1,
            4,
            "every body occurrence of the excluded value stays visible: \(body)"
        )
        // The only PHONE token left stands for the OTHER phone: the excluded
        // value never minted one, so the numbering never reached it.
        XCTAssertEqual(
            body.components(separatedBy: "{PHONE_").count - 1,
            1,
            "exactly one PHONE token, and it is not the excluded value's: \(body)"
        )

        let header = try DocxFixtureSupport.part("word/header1.xml", in: result.redactedFileURL)
        XCTAssertTrue(header.contains(Self.repeatedPhone), "the header occurrence stays visible too: \(header)")
        XCTAssertFalse(header.contains("{PHONE_"), "no PHONE token in the header part: \(header)")

        // A different value of the same type is still fully tokenized.
        XCTAssertFalse(body.contains(Self.otherPhone), "another value is still redacted: \(body)")
        XCTAssertFalse(body.contains(Self.firstEmail), "another type is still redacted: \(body)")
        XCTAssertTrue(body.contains("{EMAIL_1}"), body)

        // Four body occurrences plus the header one are now in clear, and
        // they are all the SAME value.
        XCTAssertEqual(result.excludedEntityCount, 5)
        XCTAssertEqual(result.excludedValueCount, 1)
        XCTAssertFalse(result.entities.contains { $0.text == Self.repeatedPhone })

        let mapping = try loadMapping(result)
        XCTAssertFalse(
            mapping.entries.values.contains { $0.value == Self.repeatedPhone },
            "an excluded value must not enter the mapping sidecar at any site"
        )
        XCTAssertTrue(mapping.entries.values.contains { $0.value == Self.otherPhone })
    }

    // MARK: - Type exclusions reach every channel

    func testExcludedTypesVanishFromBodyAndHeaderParts() throws {
        let input = workDir.appendingPathComponent("agreement.docx")
        try DocxFixtureSupport.write(
            paragraphs: [[
                .plain("Contact "),
                .bold(Self.firstEmail),
                .plain(" before \(Self.bodyDate).")
            ]],
            header: [[.plain("Dated \(Self.headerDate)")]],
            to: input
        )

        // Control: without exclusions the header date is tokenized.
        let control = try LDAService.anonymize(
            input: input,
            outputDir: outputDir("control"),
            protection: protection,
            createdAtISO8601: Self.createdAt
        )
        let controlHeader = try DocxFixtureSupport.part("word/header1.xml", in: control.redactedFileURL)
        XCTAssertTrue(controlHeader.contains("{DATE_"), "fixture: the header date must be detectable")
        XCTAssertFalse(controlHeader.contains(Self.headerDate))

        // With DATE excluded, no DATE token exists in any part and both dates stay.
        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir("excluded"),
            protection: protection,
            createdAtISO8601: Self.createdAt,
            excludedTypes: [.date]
        )
        let header = try DocxFixtureSupport.part("word/header1.xml", in: result.redactedFileURL)
        XCTAssertTrue(header.contains(Self.headerDate), "the header date stays visible")
        XCTAssertFalse(header.contains("{DATE_"), "no DATE token in the header part")

        let body = try DocxFixtureSupport.part(docxMainPartPath, in: result.redactedFileURL)
        XCTAssertTrue(body.contains(Self.bodyDate), "the body date stays visible")
        XCTAssertFalse(body.contains("{DATE_"), "no DATE token in the body")
        XCTAssertTrue(body.contains("{EMAIL_1}"), "the email is still redacted")
        XCTAssertFalse(body.contains(Self.firstEmail))

        XCTAssertFalse(result.entities.contains { $0.type == .date })
        XCTAssertEqual(
            result.excludedEntityCount,
            2,
            "the body DATE and the header DATE are both in clear"
        )
        XCTAssertEqual(result.excludedValueCount, 2, "two distinct dates")
        let mapping = try loadMapping(result)
        XCTAssertFalse(mapping.entries.values.contains { $0.type == .date })
    }

    // MARK: - Sessions

    func testSessionExcludedTypesApplyToEveryDocument() throws {
        let first = try writeText(
            "Filed by \(Self.firstEmail) on \(Self.bodyDate).",
            named: "complaint.txt"
        )
        let second = try writeText(
            "Reply to \(Self.firstEmail) before \(Self.headerDate).",
            named: "annex.txt"
        )

        let session = try LDAService.anonymizeSession(
            inputs: [first, second],
            createdAtISO8601: Self.createdAt,
            excludedTypes: [.date]
        )

        XCTAssertEqual(session.documents.count, 2)
        for document in session.documents {
            XCTAssertFalse(document.redactedMarkdown.contains("{DATE_"), document.redactedMarkdown)
            XCTAssertTrue(document.redactedMarkdown.contains("{EMAIL_1}"), document.redactedMarkdown)
            XCTAssertFalse(document.entities.contains { $0.type == .date })
            XCTAssertEqual(document.excludedEntityCount, 1)
        }
        XCTAssertTrue(session.documents[0].redactedMarkdown.contains(Self.bodyDate))
        XCTAssertTrue(session.documents[1].redactedMarkdown.contains(Self.headerDate))
        XCTAssertFalse(session.mapping.entries.values.contains { $0.type == .date })
    }
}

/// Excludes the FIRST occurrence of one value and keeps every other span, the
/// way an MCP caller names a single detected occurrence by its id. A reference
/// type because the seam is consulted span by span and the verdict depends on
/// what came before.
private final class ExcludeFirstOccurrence {

    private let value: String
    private(set) var matchCount = 0
    private var excluded = false

    init(of value: String) {
        self.value = value
    }

    func keep(_ span: Span) -> Bool {
        guard span.text == value else { return true }
        matchCount += 1
        guard !excluded else { return true }
        excluded = true
        return false
    }
}
