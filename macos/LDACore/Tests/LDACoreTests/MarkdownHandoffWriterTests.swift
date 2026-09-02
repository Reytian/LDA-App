//
//  MarkdownHandoffWriterTests.swift
//  LDACoreTests
//
//  The Markdown file Export for AI writes: the body is the session's combined
//  redacted text, verbatim, and the token style alone gets a one-line
//  preamble telling the AI what the placeholders are. The preamble must never
//  carry a literal token, because a literal token would be restored to a real
//  value on the way back.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class MarkdownHandoffWriterTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownHandoffWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private static let combined = "# Document 1\n\nMail {EMAIL_1} please.\n\n---\n\n# Document 2\n\nAlso {EMAIL_2}."

    // MARK: - render

    func testTokenStyleOpensWithThePreambleAndKeepsTheBodyVerbatim() {
        let rendered = MarkdownHandoffWriter.render(combined: Self.combined, style: .token)

        XCTAssertEqual(
            rendered,
            MarkdownHandoffWriter.tokenStylePreamble + "\n\n" + Self.combined
        )
    }

    func testLiteralStylesRenderTheBodyWithoutAPreamble() {
        let body = "甲公司 owes 乙公司 the balance."

        XCTAssertEqual(MarkdownHandoffWriter.render(combined: body, style: .pseudonym), body)
        XCTAssertEqual(MarkdownHandoffWriter.render(combined: body, style: .asterisk), body)
    }

    func testThePreambleCarriesNoPlaceholderAndRestoresCleanly() throws {
        // Arrange: a real token-style mapping over a one-line document.
        let text = "Mail john@acme.com please."
        let tokenized = try Tokenizer.requireSafeForRelease(
            Tokenizer.tokenize(
                text: text,
                spans: DeterministicEngine().detect(text),
                sourceFile: "a.txt",
                createdAtISO8601: "2026-09-02T00:00:00Z",
                seedMapping: nil,
                style: .token
            )
        )
        XCTAssertEqual(tokenized.tokenizedText, "Mail {EMAIL_1} please.")

        // Act: restore the rendered file exactly as the AI would hand it back.
        let rendered = MarkdownHandoffWriter.render(combined: tokenized.tokenizedText, style: .token)
        let restored = Restorer.restore(text: rendered, mapping: tokenized.mapping)

        // Assert: the preamble is inert. Nothing in it restores, nothing in it
        // is flagged as a damaged placeholder, and the body comes back whole.
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertTrue(restored.orphanTokens.isEmpty, "\(restored.orphanTokens)")
        XCTAssertTrue(restored.suspectPlaceholders.isEmpty, "\(restored.suspectPlaceholders)")
        XCTAssertTrue(restored.text.hasSuffix("Mail john@acme.com please."))
        XCTAssertFalse(MarkdownHandoffWriter.tokenStylePreamble.contains("{"))
        XCTAssertFalse(MarkdownHandoffWriter.tokenStylePreamble.contains("}"))
        XCTAssertFalse(MarkdownHandoffWriter.tokenStylePreamble.contains("\u{2014}"))
        XCTAssertFalse(MarkdownHandoffWriter.tokenStylePreamble.contains("\u{2013}"))
    }

    // MARK: - write

    func testWriteStoresUTF8ThatReadsBackIdentically() throws {
        let url = workDir.appendingPathComponent("Redacted for AI.md")
        let markdown = MarkdownHandoffWriter.render(combined: "张三 signs as {PERSON_1}.", style: .token)

        try MarkdownHandoffWriter.write(markdown, to: url)

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), markdown)
    }

    func testWriteRefusesAnUnwritableDestination() {
        let missingDir = workDir.appendingPathComponent("missing", isDirectory: true)
        let url = missingDir.appendingPathComponent("Redacted for AI.md")

        XCTAssertThrowsError(try MarkdownHandoffWriter.write("body", to: url))
    }
}
