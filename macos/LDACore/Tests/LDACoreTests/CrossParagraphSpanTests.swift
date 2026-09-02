//
//  CrossParagraphSpanTests.swift
//  LDACoreTests
//
//  A detected entity can straddle a DOCX paragraph break ("John\nSmith" where
//  the name wraps across paragraphs). The paragraph newline is synthetic (it
//  exists in the imported text but in no run), so a replacement carrying it
//  cannot round-trip: restoring would push a literal newline into a single
//  w:t element and the re-imported text diverges from the original. Such
//  spans must be split into per-paragraph sub-spans before tokenization.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class CrossParagraphSpanTests: XCTestCase {

    // MARK: - Splitter unit behavior

    func testSplitterPassesThroughNewlineFreeSpans() {
        let text = "Pay Alice now."
        let spans = EntityLocator.spans(forValue: "Alice", type: .person, in: text)
        let split = SpanSplitter.splitAtBreaks(spans, in: text)
        XCTAssertEqual(split, spans)
    }

    func testSplitterSplitsNewlineCrossingSpanIntoPerLineParts() {
        let text = "Signed by John\nSmith the buyer."
        let spans = EntityLocator.spans(forValue: "John\nSmith", type: .person, in: text)
        XCTAssertEqual(spans.count, 1, "fixture: the cross-paragraph value must locate")

        let split = SpanSplitter.splitAtBreaks(spans, in: text)

        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split.map { $0.text }, ["John", "Smith"])
        // Offsets must slice back exactly.
        let ns = text as NSString
        for part in split {
            let slice = ns.substring(with: NSRange(location: part.start, length: part.end - part.start))
            XCTAssertEqual(slice, part.text)
            XCTAssertEqual(part.type, .person)
        }
    }

    func testSplitterDropsWhitespaceOnlyParts() {
        let text = "A\n \nB"
        let span = Span(
            start: 0, end: 5, type: .person, text: "A\n \nB",
            source: .llm, confidence: 0.9, priority: 30
        )
        let split = SpanSplitter.splitAtBreaks([span], in: text)
        XCTAssertEqual(split.map { $0.text }, ["A", "B"])
    }

    // MARK: - Service-level DOCX round trip

    /// A fake completer that always reports the cross-paragraph PERSON value.
    private struct CrossParagraphCompleter: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return #"{"entities":[{"value":"John\nSmith","type":"PERSON"}],"redacted_text":""}"#
        }
    }

    override func setUp() {
        super.setUp()
        // Fail here if an earlier suite leaked a process-wide test seam.
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    /// End to end on a two-paragraph DOCX where the LLM reports "John\nSmith":
    /// the redacted docx must contain neither name part, and restore must be
    /// byte-identical to the original import.
    func testDocxCrossParagraphEntityRedactsAndRoundTrips() throws {
        // Two paragraphs; the entity value spans the paragraph break.
        let docx = try makeTwoParagraphDocx(first: "Signed by John", second: "Smith the buyer.")
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xpara-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: workDir) }

        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: CrossParagraphCompleter())
        }

        let originalText = try DocxImporter().importDocument(docx).text
        XCTAssertTrue(originalText.contains("John\nSmith"), "fixture must cross paragraphs")

        let result = try LDAService.anonymize(
            input: docx,
            outputDir: workDir,
            protection: .passphrase("test-passphrase"),
            createdAtISO8601: "2026-01-01T00:00:00Z",
            llmModelPath: "/nonexistent/model.gguf"
        )

        // Both halves of the name must be gone from the redacted edit surface.
        let redactedText = try DocxImporter().importDocument(result.redactedFileURL).text
        XCTAssertFalse(redactedText.contains("John"), "first half leaked: \(redactedText)")
        XCTAssertFalse(redactedText.contains("Smith"), "second half leaked: \(redactedText)")

        // Restore must reproduce the original import byte for byte.
        let restoredURL = workDir.appendingPathComponent("restored.docx")
        _ = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("test-passphrase"),
            output: restoredURL
        )
        let restoredText = try DocxImporter().importDocument(restoredURL).text
        XCTAssertEqual(
            Array(restoredText.utf16),
            Array(originalText.utf16),
            "cross-paragraph restore must be byte-identical"
        )
    }

    // MARK: - Fixture

    private func makeTwoParagraphDocx(first: String, second: String) throws -> URL {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">\(first)</w:t></w:r></w:p>\
        <w:p><w:r><w:t xml:space="preserve">\(second)</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xpara-\(UUID().uuidString).docx")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        try DocxZip.writeArchive(
            parts: [
                ("[Content_Types].xml", Data(contentTypes.utf8)),
                ("_rels/.rels", Data(rels.utf8)),
                ("word/document.xml", Data(document.utf8))
            ],
            to: url
        )
        return url
    }
}
