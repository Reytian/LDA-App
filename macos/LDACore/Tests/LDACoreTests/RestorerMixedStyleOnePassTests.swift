//
//  RestorerMixedStyleOnePassTests.swift
//  LDACoreTests
//
//  Review finding 12 (2026-09-06): a token-style mapping can carry pseudonym
//  entries from an earlier style. Restore used to expand the brace tokens
//  first and then search THAT output for the carried pseudonyms, so the
//  second pass could match inside an original value the first pass had just
//  put back, and silently rewrite it. The evidence: with a carried binding
//  "Person A" -> Alice, the company "Person A Holdings" tokenized to
//  {COMPANY_1} and restored to "Alice Holdings", reported as two restorations.
//
//  The invariant pinned here: every substitution site, brace token or carried
//  literal, is planned against the text the caller handed in, in one pass. A
//  value written by the restore is never searched again. The DOCX token-style
//  write reaches the same sites as the text report, and the text write stays
//  byte-identical to the preview.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class RestorerMixedStyleOnePassTests: XCTestCase {

    private let stamp = "2026-09-06T00:00:00Z"

    /// The seed the review used: a pseudonym-style binding carried into a
    /// token-style run. Its replacement is ordinary text, not a brace token.
    private var carriedPseudonymSeed: Mapping {
        Mapping(
            entries: [
                "Person A": MappingEntry(
                    token: "Person A",
                    value: "Alice",
                    type: .person,
                    surfaceText: "Alice",
                    aliases: []
                )
            ],
            createdAtISO8601: stamp,
            sourceFile: "seed",
            style: .pseudonym
        )
    }

    /// Token-style tokenization of the review's company name against the
    /// carried seed. The union mapping holds both replacement shapes.
    private func tokenizeHoldings() -> TokenizeResult {
        let text = "Person A Holdings"
        let span = Span(
            start: 0,
            end: text.utf16.count,
            type: .company,
            text: text,
            source: .manual,
            confidence: 1,
            priority: 1
        )
        return Tokenizer.tokenize(
            text: text,
            spans: [span],
            sourceFile: "new",
            createdAtISO8601: stamp,
            seedMapping: carriedPseudonymSeed,
            style: .token
        )
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-mixed-\(UUID().uuidString)-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - The review's evidence

    /// A carried pseudonym must never match inside an original value the
    /// token substitution just restored.
    func testCarriedPseudonymDoesNotRewriteAnOriginalTheTokenPassJustRestored() {
        let mixed = tokenizeHoldings()
        XCTAssertEqual(mixed.tokenizedText, "{COMPANY_1}")
        XCTAssertEqual(mixed.mapping.entries["Person A"]?.value, "Alice", "the seed entry is carried")

        let restored = Restorer.restore(text: mixed.tokenizedText, mapping: mixed.mapping)

        XCTAssertEqual(restored.text, "Person A Holdings")
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
    }

    /// Both shapes are planned against the returned text in one pass: the
    /// brace token restores, a genuine carried-literal site restores, and the
    /// restored company name is not searched again.
    func testTokenAndGenuineCarriedLiteralSiteRestoreTogetherInOnePass() {
        let mixed = tokenizeHoldings()
        let returned = "{COMPANY_1} and Person A met Person A."

        let restored = Restorer.restore(text: returned, mapping: mixed.mapping)

        XCTAssertEqual(restored.text, "Person A Holdings and Alice met Alice.")
        XCTAssertEqual(restored.restoredCount, 3)
        XCTAssertTrue(restored.orphanTokens.isEmpty)
    }

    /// A carried literal adjacent to a token site still restores at its own
    /// site only; the value emitted for the token is not part of the scan.
    func testCarriedLiteralAdjacentToATokenSiteRestoresOnlyItself() {
        let mixed = tokenizeHoldings()

        let restored = Restorer.restore(text: "{COMPANY_1}Person A", mapping: mixed.mapping)

        XCTAssertEqual(restored.text, "Person A HoldingsAlice")
        XCTAssertEqual(restored.restoredCount, 2)
    }

    // MARK: - Surface parity

    /// The DOCX token-style write is a different mechanism from the text
    /// scan (a run rewrite planned over each part's text). For a mapping that
    /// carries a pseudonym it must substitute exactly the sites the report
    /// counts: the brace token, the genuine carried-literal paragraph, and
    /// nothing inside the restored company name.
    func testTokenStyleDocxWriteAgreesWithTheReportWhenTheMappingCarriesAPseudonym() throws {
        let mixed = tokenizeHoldings()
        let docx = tempURL("in.docx")
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run("{COMPANY_1}"))
                + DocxTestPackage.paragraph(DocxTestPackage.run("Person A")),
            to: docx
        )
        let out = tempURL("out.docx")

        let preview = try LDAService.restorePreview(editedRedacted: docx, mapping: mixed.mapping)
        let report = try LDAService.restore(editedRedacted: docx, mapping: mixed.mapping, output: out)
        let written = try DocxImporter().importDocument(out).text

        XCTAssertEqual(written, preview.restoredText, "the written document must be the reported text")
        XCTAssertEqual(report.restoredCount, preview.restoredCount)
        XCTAssertEqual(report.ambiguousReplacements, preview.ambiguousReplacements)
        XCTAssertEqual(report.orphanTokens, preview.orphanTokens)

        XCTAssertEqual(preview.restoredCount, 2)
        XCTAssertTrue(written.contains("Person A Holdings"), "the company name restores whole: \(written)")
        XCTAssertTrue(written.contains("Alice"), "the genuine carried-literal site restores: \(written)")
        XCTAssertFalse(written.contains("Alice Holdings"), "the restored value was searched again: \(written)")
    }

    /// The text write reads the same preview it shows, so its bytes cannot
    /// drift from it under a mixed mapping either.
    func testTextWriteStaysByteIdenticalToThePreviewForAMixedMapping() throws {
        let mixed = tokenizeHoldings()
        let input = tempURL("in.md")
        try "{COMPANY_1} and Person A.".write(to: input, atomically: true, encoding: .utf8)
        let out = tempURL("out.md")

        let preview = try LDAService.restorePreview(editedRedacted: input, mapping: mixed.mapping)
        let report = try LDAService.restore(editedRedacted: input, mapping: mixed.mapping, output: out)
        let written = try String(contentsOf: out, encoding: .utf8)

        XCTAssertEqual(written, preview.restoredText)
        XCTAssertEqual(written, "Person A Holdings and Alice.")
        XCTAssertEqual(report.restoredCount, preview.restoredCount)
        XCTAssertEqual(report.restoredCount, 2)
    }

    /// The paste path (the MCP restore of pasted text, the menu-bar Restore
    /// Clipboard) loads the mapping back from its encrypted sidecar and runs
    /// the same engine as the file path. The carried pseudonym entry and the
    /// token style must survive that round trip, or the two paths would take
    /// different decisions over the same reply.
    func testPastedTextRestoreAgreesWithTheEngineForAMixedMapping() throws {
        let mixed = tokenizeHoldings()
        let mappingURL = tempURL("mixed.ldamap")
        try MappingStore.save(mixed.mapping, to: mappingURL, protection: .passphrase("pw"))
        let returned = "{COMPANY_1} and Person A."

        let pasted = try LDAService.restoreText(
            returned,
            mapping: mappingURL,
            protection: .passphrase("pw")
        )
        let engine = Restorer.restore(text: returned, mapping: mixed.mapping)

        XCTAssertEqual(pasted.text, "Person A Holdings and Alice.")
        XCTAssertEqual(pasted.text, engine.text)
        XCTAssertEqual(pasted.restoredCount, 2)
        XCTAssertEqual(pasted.restoredCount, engine.restoredCount)
        XCTAssertEqual(pasted.orphanTokens, engine.orphanTokens)
        XCTAssertEqual(pasted.ambiguousReplacements, engine.ambiguousReplacements)
    }
}
