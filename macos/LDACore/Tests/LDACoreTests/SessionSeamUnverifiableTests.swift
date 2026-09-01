//
//  SessionSeamUnverifiableTests.swift
//  LDACoreTests
//
//  What the session seam pass does when it cannot check its own work.
//
//  SessionSeamVerifier re-renders the document to recover where each emitted
//  replacement landed, and that rendering must reproduce the tokenized text
//  exactly. When it does not, the piece offsets are fiction and the pass
//  cannot tell a legitimate substitution site from a coincidence.
//
//  Returning "no violations found" in that case is the one answer it must not
//  give. "No violations found" is what a clean session returns, and it is what
//  lets the redacted text out of the door: an empty unresolvedSeams list is the
//  signal every consumer reads as safe. A pass that answers "all clear" when it
//  has checked nothing is worse than no pass at all, because the whole point of
//  the give-up path is that a literal-restore seam cannot be caught anywhere
//  later in the round trip.
//
//  So the distinction under test is between the two things an empty violation
//  list can mean: I CHECKED AND FOUND NOTHING, versus I COULD NOT CHECK. The
//  first is safe. The second must reach the user.
//
//  House rules: all comments and strings in English. Fixture strings and
//  pseudonyms may be Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SessionSeamUnverifiableTests: XCTestCase {

    private let timestamp = "2026-09-01T00:00:00Z"

    private func span(
        _ text: String,
        in document: String,
        type: EntityType
    ) -> Span {
        let ns = document as NSString
        let range = ns.range(of: text)
        precondition(range.location != NSNotFound, "fixture span must exist")
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: text,
            source: .llm,
            confidence: 0.99,
            priority: 10
        )
    }

    override func tearDown() {
        SessionSeamVerifier.unverifiableSeam.clear()
        super.tearDown()
    }

    // MARK: - The verifier itself

    /// The precondition failure must be reported, not swallowed.
    ///
    /// The inputs here are deliberately inconsistent: the spans and the
    /// assignment render "甲公司 and Party B", but the tokenized text handed in
    /// is something else entirely. That is exactly the state the guard exists
    /// to detect, and the honest answer is "I could not check this document".
    func testTheVerifierReportsThatItCouldNotCheckWhenTheRenderDisagrees() {
        let original = "Party A and Party B"
        let spans = [span("Party A", in: original, type: .company)]

        let report = SessionSeamVerifier.report(
            documentIndex: 0,
            tokenizedText: "a completely different string",
            originalText: original,
            acceptedSpans: spans,
            replacementBySurface: ["Party A": "甲公司"],
            replacements: ["甲公司"]
        )

        XCTAssertTrue(
            report.couldNotVerify,
            "the pass could not establish its own precondition and must say so"
        )
        XCTAssertTrue(
            report.violations.isEmpty,
            "it found no violations because it never looked, so it must not "
                + "invent any either"
        )
    }

    /// The negative control that keeps the test above from passing vacuously.
    ///
    /// Same shape, but with a tokenized text that IS what the assignment
    /// renders. If this ever reported couldNotVerify, the check above would
    /// pass for the wrong reason and every clean session would warn.
    func testTheVerifierChecksNormallyWhenTheRenderAgrees() {
        let original = "Party A and Party B"
        let spans = [span("Party A", in: original, type: .company)]

        let report = SessionSeamVerifier.report(
            documentIndex: 0,
            tokenizedText: "甲公司 and Party B",
            originalText: original,
            acceptedSpans: spans,
            replacementBySurface: ["Party A": "甲公司"],
            replacements: ["甲公司"]
        )

        XCTAssertFalse(
            report.couldNotVerify,
            "the render reproduced the tokenized text, so the pass ran"
        )
        XCTAssertTrue(report.violations.isEmpty, "nothing is wrong with this document")
    }

    // MARK: - Out to the caller

    /// The end of the wire: a session the pass could not check must come back
    /// warning, through the same unresolvedSeams channel the CLI, the GUI and
    /// the MCP tool already read.
    ///
    /// The precondition holds in every real run, which is why this is driven
    /// through a DEBUG-only seam rather than a contrived document. That is the
    /// established way to reach an unreachable-by-design path in this codebase
    /// (see the librarySeam and clientStoreSeam precedents).
    func testASessionTheSeamPassCouldNotCheckComesBackWarning() {
        SessionSeamVerifier.unverifiableSeam.value = true

        let documentOne = "本协议由天海科技有限公司与王小明签署。"
        let documents = [
            SessionDocument(
                name: "contract.docx",
                text: documentOne,
                spans: [
                    span("天海科技有限公司", in: documentOne, type: .company),
                    span("王小明", in: documentOne, type: .person)
                ]
            )
        ]

        let session = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        XCTAssertFalse(
            session.unresolvedSeams.isEmpty,
            "the seam check did not run, so the session must not be handed "
                + "back as if it had been verified"
        )
        XCTAssertEqual(
            session.documents.count,
            1,
            "warn, do not block: the documents are still produced"
        )
    }

    /// The warning has to name the document, because a user with a ten document
    /// session needs to know which file is unverified.
    func testTheWarningNamesTheDocumentItCouldNotCheck() {
        SessionSeamVerifier.unverifiableSeam.value = true

        let text = "本协议由天海科技有限公司签署。"
        let documents = [
            SessionDocument(
                name: "share-purchase.docx",
                text: text,
                spans: [span("天海科技有限公司", in: text, type: .company)]
            )
        ]

        let session = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        XCTAssertTrue(
            session.unresolvedSeams.contains { $0.contains("share-purchase.docx") },
            "expected the document name in: \(session.unresolvedSeams)"
        )
    }

    /// A pass that cannot check a document also cannot repair it: there is no
    /// matched replacement to ban, so reminting would spin without ever
    /// changing the outcome. It has to give up immediately instead of grinding
    /// through the repair cap first.
    ///
    /// Timed rather than counted because the repair cap is private. A session
    /// this small folds in milliseconds, so a generous ceiling still catches a
    /// loop that runs the cap out.
    func testAnUncheckableSessionGivesUpAtOnceRatherThanRemintingInCircles() {
        SessionSeamVerifier.unverifiableSeam.value = true

        let text = "本协议由天海科技有限公司与王小明签署。"
        let documents = [
            SessionDocument(
                name: "contract.docx",
                text: text,
                spans: [
                    span("天海科技有限公司", in: text, type: .company),
                    span("王小明", in: text, type: .person)
                ]
            )
        ]

        let started = Date()
        let session = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(session.unresolvedSeams.isEmpty)
        XCTAssertLessThan(
            elapsed,
            2.0,
            "gave up after \(elapsed)s, which suggests it re-folded the session "
                + "on a report no remint can change"
        )
    }

    /// The whole-suite guard: with no seam installed, an ordinary session is
    /// still silent. This is what would break if the fix made the pass warn
    /// whenever it was merely unsure.
    func testAnOrdinarySessionStillReportsNothing() {
        let documentOne = "本协议由天海科技有限公司与王小明签署。"
        let documentTwo = "天海科技有限公司确认前述条款，王小明为联系人。"
        let documents = [
            SessionDocument(
                name: "one.docx",
                text: documentOne,
                spans: [
                    span("天海科技有限公司", in: documentOne, type: .company),
                    span("王小明", in: documentOne, type: .person)
                ]
            ),
            SessionDocument(
                name: "two.docx",
                text: documentTwo,
                spans: [
                    span("天海科技有限公司", in: documentTwo, type: .company),
                    span("王小明", in: documentTwo, type: .person)
                ]
            )
        ]

        let session = SessionTokenizer.tokenize(
            documents: documents,
            sourceLabel: "session",
            createdAtISO8601: timestamp,
            style: .pseudonym
        )

        XCTAssertTrue(
            session.unresolvedSeams.isEmpty,
            "a clean session must stay silent: \(session.unresolvedSeams)"
        )
        for (index, document) in documents.enumerated() {
            let restored = Restorer.restore(
                text: session.documents[index].tokenizedText,
                mapping: session.mapping
            )
            XCTAssertEqual(restored.text, document.text)
        }
    }

    /// The seam must not exist in a shipping binary, and must not leak into
    /// later tests in this process.
    func testTheSeamIsNotInstalledByDefault() {
        XCTAssertFalse(
            SessionSeamVerifier.unverifiableSeam.isInstalled,
            "a seam left installed turns every later session in this process "
                + "into a warning"
        )
    }
}
