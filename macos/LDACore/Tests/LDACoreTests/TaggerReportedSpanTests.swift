//
//  TaggerReportedSpanTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F2. The filters LDA wrote for an LLM's over-reporting
//  (LegalBoilerplate's head nouns, its lowercase rule, the defined-term and
//  needle-safety checks) also deleted names the LDA V4 tagger had located
//  exactly. "Hartwell Law LLP ("Hartwell Law") ... Hartwell Law will file"
//  redacted the full name and left "Hartwell Law" three times, because a
//  company value ending in "law" reads as a statute; short names ending in
//  Court, Plan, Policy, Information, Release, Notice and Rules behaved the
//  same, and lowercase names in a chat export stayed visible because a value
//  with no capital letter reads as prose.
//
//  A span the tagger reported is now redacted at the place it was reported;
//  the filters decide only whether that value is spread to its other
//  occurrences. A defined short name bound to a redacted full name is
//  redacted, even when the tagger calls it a court (KEEP_ORG).
//
//  The tagger's own output for the review's probe (inputs/v/t5_law.txt) is
//  replayed here span for span, as the live model reported it, so these tests
//  need no Core ML model. The live test at the end runs the real tagger when
//  LDA_V4_MODEL_DIR names a model folder.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class TaggerReportedSpanTests: XCTestCase {

    /// inputs/v/t5_law.txt, verbatim.
    static let probe = """
    (Fictional) Hartwell Law LLP ("Hartwell Law") represents Jordan Ellis. Hartwell Law will file the motion on \
    Monday. All invoices of Hartwell Law are payable in 30 days. Brightwater Court Inc. ("Brightwater Court") is the \
    landlord, and Brightwater Court has not replied. Messages from sam okafor and dana whitford were exported from \
    the chat: "sam okafor: please send the draft to dana whitford".
    """

    /// What the live tagger reported for `probe` (UTF-16 ranges and labels).
    static let probeTaggerOutput: [(start: Int, end: Int, label: String)] = [
        (12, 28, "COMPANY"), (31, 43, "COMPANY"), (57, 69, "PERSON"), (71, 83, "COMPANY"), (132, 144, "COMPANY"),
        (169, 191, "COMPANY"), (194, 211, "KEEP_ORG"), (235, 252, "KEEP_ORG"),
        (284, 294, "PERSON"), (299, 312, "PERSON"), (343, 353, "PERSON"), (380, 393, "PERSON"),
    ]

    /// Stands in for the Core ML model: replays fixed tagger spans through
    /// LDAV4Extractor's own value and filter logic.
    private final class ReplayedTagger: EntityExtracting {
        let output: [(start: Int, end: Int, label: String)]
        init(_ output: [(start: Int, end: Int, label: String)]) { self.output = output }
        func extract(from text: String, onProgress: ((Int, Int) -> Void)?) throws -> [Span] {
            try extractDetailed(from: text, onProgress: onProgress).spans
        }
        func extractDetailed(from text: String, onProgress: ((Int, Int) -> Void)?) throws -> ExtractionResult {
            LDAV4Extractor.result(forTaggerSpans: output, in: text)
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
    }

    /// Every occurrence of each value, longer values first, never inside a
    /// range already taken: the shape a tagger reports.
    private func reported(_ text: String, _ items: [(String, String)]) -> [(start: Int, end: Int, label: String)] {
        let ns = text as NSString
        var taken: [(start: Int, end: Int, label: String)] = []
        for (value, label) in items.sorted(by: { $0.0.count > $1.0.count }) {
            var from = 0
            while from < ns.length {
                let range = ns.range(of: value, range: NSRange(location: from, length: ns.length - from))
                guard range.location != NSNotFound else { break }
                let end = range.location + range.length
                if !taken.contains(where: { $0.start < end && $0.end > range.location }) {
                    taken.append((range.location, end, label))
                }
                from = end
            }
        }
        return taken.sorted { $0.start < $1.start }
    }

    private func covered(_ spans: [Span], _ start: Int, _ end: Int) -> Bool {
        spans.contains { $0.start <= start && $0.end >= end }
    }

    private func visible(_ spans: [Span], in text: String) -> String {
        var out = text as NSString
        for span in spans.sorted(by: { $0.start > $1.start }) {
            out = out.replacingCharacters(in: NSRange(location: span.start, length: span.end - span.start),
                                          with: "{\(span.type.rawValue)}") as NSString
        }
        return out as String
    }

    // MARK: - The extractor: reported spans stay redacted where reported

    func testEveryPlaceTheTaggerReportedHartwellLawIsRedacted() {
        let result = LDAV4Extractor.result(forTaggerSpans: Self.probeTaggerOutput, in: Self.probe)
        for (start, end) in [(31, 43), (71, 83), (132, 144)] {
            XCTAssertTrue(covered(result.spans, start, end),
                          "the tagger located Hartwell Law at \(start), it must be redacted there: \(visible(result.spans, in: Self.probe))")
        }
    }

    func testLowercaseNamesTheTaggerReportedAreRedacted() {
        let text = "[10:02] sam okafor: ok\n[10:03] dana whitford: please call wang jianguo\n[10:04] wang jianguo: thanks"
        let output = reported(text, [("sam okafor", "PERSON"), ("dana whitford", "PERSON"), ("wang jianguo", "PERSON")])
        let result = LDAV4Extractor.result(forTaggerSpans: output, in: text)
        let shown = visible(result.spans, in: text)
        for name in ["sam okafor", "dana whitford", "wang jianguo"] {
            XCTAssertFalse(shown.contains(name), "\(name) stayed visible: \(shown)")
        }
    }

    func testShortNamesEndingInAnInstrumentWordAreRedactedWhereReported() {
        let names = ["Brightwater Court", "Meridian Plan", "Northwind Policy", "Harbor Information",
                     "Atlas Release", "Kestrel Notice", "Quinn Rules"]
        let text = names.map { "\($0) signed the lease." }.joined(separator: " ")
        let result = LDAV4Extractor.result(forTaggerSpans: reported(text, names.map { ($0, "COMPANY") }), in: text)
        let shown = visible(result.spans, in: text)
        for name in names {
            XCTAssertFalse(shown.contains(name), "\(name) stayed visible: \(shown)")
        }
    }

    func testTheFiltersStillDecideWhetherAValueIsSpread() {
        // Reported once, written twice: a value the boilerplate filter would
        // drop is redacted where it was reported and not spread, as NameHeads
        // already behaves; a value that passes is spread to its repeat.
        let text = "Quinn Rules filed first. Quinn Rules are strict. Jordan Ellis agreed, and Jordan Ellis signed."
        let ns = text as NSString
        let first = ns.range(of: "Quinn Rules")
        let person = ns.range(of: "Jordan Ellis")
        let result = LDAV4Extractor.result(forTaggerSpans: [
            (first.location, first.location + first.length, "COMPANY"),
            (person.location, person.location + person.length, "PERSON"),
        ], in: text)
        XCTAssertTrue(covered(result.spans, first.location, first.location + first.length))
        let second = ns.range(of: "Quinn Rules", options: .backwards)
        XCTAssertFalse(covered(result.spans, second.location, second.location + second.length),
                       "a boilerplate-shaped value is not spread to places the tagger did not report")
        let repeatPerson = ns.range(of: "Jordan Ellis", options: .backwards)
        XCTAssertTrue(covered(result.spans, repeatPerson.location, repeatPerson.location + repeatPerson.length),
                      "a value that passes the filters is still spread")
    }

    func testASpanThatEndsInsideAWordIsNotPinnedHalfway() {
        // A tagger span that stops inside a word cannot be redacted at its
        // place without leaving the rest of the word beside the token, so it
        // is left to the locator, which reports it as unlocated.
        let text = "Signed by Mr. Mateo Ashdown on Monday."
        let ns = text as NSString
        let start = ns.range(of: "Mr. Mateo Ash").location
        let result = LDAV4Extractor.result(forTaggerSpans: [(start, start + 13, "PERSON")], in: text)
        XCTAssertFalse(result.spans.contains { $0.start == start && $0.end == start + 13 })
    }

    // MARK: - The detector: defined short names bound to a redacted full name

    func testTheProbeIsFullyRedactedThroughTheDetector() throws {
        let detector = LDAService.Detector(extractor: ReplayedTagger(Self.probeTaggerOutput))
        let spans = try detector.detectText(Self.probe)
        let shown = visible(spans, in: Self.probe)
        for name in ["Hartwell", "Brightwater", "sam okafor", "dana whitford", "Jordan Ellis"] {
            XCTAssertFalse(shown.contains(name), "\(name) stayed visible: \(shown)")
        }
    }

    func testADefinedShortNameBoundToARedactedFullNameIsRedactedEverywhere() throws {
        // The tagger reports only the full names. The short names are defined
        // right after them, so they name the same parties wherever they occur.
        let text = """
        Hartwell Law LLP ("Hartwell Law") acts for the tenant. Brightwater Court Inc. ("Brightwater Court") is the \
        landlord. Hartwell Law wrote to Brightwater Court on Monday.
        """
        let output = reported(text, [("Hartwell Law LLP", "COMPANY"), ("Brightwater Court Inc.", "COMPANY")])
        let spans = try LDAService.Detector(extractor: ReplayedTagger(output)).detectText(text)
        let shown = visible(spans, in: text)
        XCTAssertFalse(shown.contains("Hartwell Law"), shown)
        XCTAssertFalse(shown.contains("Brightwater Court"), shown)
    }

    func testAGenericSingleWordDefinedTermIsStillNotSpread() throws {
        // "Seller" is a role word even when the company's name contains it.
        let text = "Seller Group Inc. (\"Seller\") sold the goods. The Seller warrants title. Any seller may object."
        let output = reported(text, [("Seller Group Inc.", "COMPANY")])
        let spans = try LDAService.Detector(extractor: ReplayedTagger(output)).detectText(text)
        let shown = visible(spans, in: text)
        XCTAssertTrue(shown.contains("Any seller may object"), shown)
    }

    // MARK: - Live

    func testTheLiveTaggerLeavesNoProbeNameVisible() throws {
        guard let folder = ProcessInfo.processInfo.environment["LDA_V4_MODEL_DIR"] else {
            throw XCTSkip("set LDA_V4_MODEL_DIR to an LDA V4 model folder to run the live tagger")
        }
        let extractor = try LDAV4Extractor(modelDirectory: URL(fileURLWithPath: folder, isDirectory: true))
        let spans = try LDAService.Detector(extractor: extractor).detectText(Self.probe)
        let shown = visible(spans, in: Self.probe)
        for name in ["Hartwell", "Brightwater", "sam okafor", "dana whitford", "Jordan Ellis"] {
            XCTAssertFalse(shown.contains(name), "\(name) stayed visible: \(shown)")
        }
    }
}
