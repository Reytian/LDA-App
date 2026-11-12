//
//  DocxSupplementaryGateTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F9. The DOCX parts outside the body (headers, footers,
//  footnotes, endnotes, comments) were detected fail-open: the detector
//  closure was (String) -> [Span], built on a best-effort pass that turned a
//  thrown extractor error, a truncated completion or a value the locator
//  could not anchor into "nothing found". The review's probe footnote
//  "See the letter signed byMarek Okafor2 on file." was exported unchanged
//  with exit 0, while the same run-in in the body refused the document.
//
//  Those parts now obey the body's gates: an extractor error, an incomplete
//  segment or an unlocated value refuses the export, or under
//  UnlocatedValuePolicy.protect is redacted at its run-in places and counted.
//  The app's export applies the same gates to the parts the user never
//  reviewed.
//
//  Every name is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class DocxSupplementaryGateTests: XCTestCase {

    static let footnote = "See the letter signed byMarek Okafor2 on file."

    private struct Completer: TextCompleter {
        enum Mode { case reports, fails, truncates }
        let mode: Mode
        struct Failure: Error {}
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            let reply = #"{"entities":[{"value":"Marek Okafor","type":"PERSON"}],"redacted_text":""}"#
            guard prompt.contains("Okafor") else { return #"{"entities":[],"redacted_text":""}"# }
            switch mode {
            case .reports: return reply
            case .fails: throw Failure()
            case .truncates: return String(reply.prefix(30))
            }
        }
    }

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxSupplementaryGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        ReviewModel.llmExtractorFactoryForTesting = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    /// A clean body and one footnote that writes a name run into the words
    /// around it.
    private func writeDocument() throws -> URL {
        let w = #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main""#
        let url = workDir.appendingPathComponent("letter.docx")
        try DocxZip.writeArchive(parts: [
            ("[Content_Types].xml", Data((#"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/></Types>"#).utf8)),
            ("_rels/.rels", Data(#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>"#.utf8)),
            ("word/_rels/document.xml.rels", Data(#"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/></Relationships>"#.utf8)),
            ("word/document.xml", Data((#"<?xml version="1.0" encoding="UTF-8"?><w:document "# + w + #"><w:body><w:p><w:r><w:t>Payment is due in thirty days.</w:t></w:r><w:r><w:footnoteReference w:id="2"/></w:r></w:p></w:body></w:document>"#).utf8)),
            ("word/footnotes.xml", Data((#"<?xml version="1.0" encoding="UTF-8"?><w:footnotes "# + w + #"><w:footnote w:id="2"><w:p><w:r><w:t>"# + Self.footnote + #"</w:t></w:r></w:p></w:footnote></w:footnotes>"#).utf8)),
        ], to: url)
        return url
    }

    private var output: URL { workDir.appendingPathComponent("out", isDirectory: true) }

    private func anonymize(_ mode: Completer.Mode, policy: UnlocatedValuePolicy = .refuse) throws -> AnonymizeResult {
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: Completer(mode: mode)) }
        return try LDAService.anonymize(
            input: try writeDocument(),
            outputDir: output,
            protection: .passphrase("supplementary-gate"),
            createdAtISO8601: "2026-11-11T00:00:00Z",
            llmModelPath: workDir.appendingPathComponent("model.gguf").path,
            unlocatedPolicy: policy
        )
    }

    private func assertNothingWritten(file: StaticString = #filePath, line: UInt = #line) {
        let written = (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? []
        XCTAssertFalse(written.contains { $0.hasSuffix(".docx") || $0.hasSuffix(".ldamap") },
                       "nothing is written: \(written)", file: file, line: line)
    }

    // MARK: - The service

    func testARunInNameInAFootnoteRefusesLikeTheBody() throws {
        XCTAssertThrowsError(try anonymize(.reports)) { error in
            guard case LDAServiceError.unanchoredEntities(let count) = error else {
                return XCTFail("expected unanchoredEntities, got \(error)")
            }
            XCTAssertEqual(count, 1)
        }
        assertNothingWritten()
    }

    func testUnderProtectTheFootnoteNameIsRedactedAtItsRunInPlaceAndCounted() throws {
        let result = try anonymize(.reports, policy: .protect)
        let footnotes = try DocxFixtureSupport.part("word/footnotes.xml", in: result.redactedFileURL)
        XCTAssertFalse(footnotes.contains("Okafor"), footnotes)
        XCTAssertTrue(footnotes.contains("by{PERSON_1}2"), "only the name is redacted: \(footnotes)")
        XCTAssertEqual(result.autoProtectedValueCount, 1)
        XCTAssertEqual(result.autoProtectedPlaceCount, 1)
    }

    func testAnExtractorErrorOnAFootnoteRefuses() throws {
        XCTAssertThrowsError(try anonymize(.fails))
        assertNothingWritten()
    }

    func testATruncatedCompletionOnAFootnoteRefuses() throws {
        XCTAssertThrowsError(try anonymize(.truncates)) { error in
            guard case LDAServiceError.incompleteExtraction = error else {
                return XCTFail("expected incompleteExtraction, got \(error)")
            }
        }
        assertNothingWritten()
    }

    // MARK: - The detect summary (independent review of F9)

    /// `lda detect` and MCP detect_entities summarized the parts outside the
    /// body with the best-effort pass, so a footnote anonymize refuses was
    /// counted as clean. The summary now refuses where the run would.
    func testTheDetectSummaryRefusesWhereTheRunWould() throws {
        let input = try writeDocument()
        let model = workDir.appendingPathComponent("model.gguf").path
        for mode in [Completer.Mode.reports, .fails, .truncates] {
            LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: Completer(mode: mode)) }
            XCTAssertThrowsError(try LDAService.detectSummary(input: input, llmModelPath: model), "\(mode)")
        }
    }

    // MARK: - The app's export

    func testTheAppsNonBodyDetectorProtectsARunInNameItFindsInAPart() throws {
        ReviewModel.llmExtractorFactoryForTesting = { _, _ in LLMExtractor(completer: Completer(mode: .reports)) }
        let model = workDir.appendingPathComponent("model.gguf")
        try Data("fixture".utf8).write(to: model)
        let detect = ReviewModel.nonBodyDetector(useLLM: true, modelPath: model.path, custom: [])
        let spans = try detect(Self.footnote)
        let name = (Self.footnote as NSString).range(of: "Marek Okafor")
        XCTAssertTrue(spans.contains { $0.start == name.location && $0.end == NSMaxRange(name) },
                      "the run-in name is redacted where it is written: \(spans)")
    }

    func testTheAppsNonBodyDetectorRefusesAPartItCouldNotScan() throws {
        ReviewModel.llmExtractorFactoryForTesting = { _, _ in LLMExtractor(completer: Completer(mode: .fails)) }
        let model = workDir.appendingPathComponent("model.gguf")
        try Data("fixture".utf8).write(to: model)
        let detect = ReviewModel.nonBodyDetector(useLLM: true, modelPath: model.path, custom: [])
        XCTAssertThrowsError(try detect(Self.footnote))
    }
}
