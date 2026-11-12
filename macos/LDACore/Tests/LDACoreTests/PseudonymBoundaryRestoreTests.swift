//
//  PseudonymBoundaryRestoreTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F10. Restore of the pseudonym style replaced every bare
//  substring: the review's reply came back with "Jordan Elliscting" (Person A
//  in "Person Acting"), "Willowcrest Studio LLCssets" (Company A in "Company
//  Assets"), "https://example.com/team2" (Item 1 in "Item 12") and
//  "i+1 (212) 555-01425" (Phone 1 in "iPhone 15"), with restoredCount 12 and
//  no warning.
//
//  A Latin pseudonym now matches only when no letter or digit touches it,
//  and a CJK pseudonym only when nothing of its own sequence continues it (a
//  digit after a digit edge, a letter after a letter edge, 某 after 某). A
//  touched occurrence is reported as a suspect placeholder instead of being
//  replaced, except where the pseudonym's final capital begins an ordinary
//  word ("Person Acting").
//
//  A document may itself write a value against a letter or digit ("signed
//  byMarek Okafor2", "建国路1号A座"). Tokenization records how the redacted
//  text spells each such site on the entry (MappingEntry.gluedSites), so the
//  document still restores to itself. An entry written before that record
//  existed keeps the old substring match, so files exported earlier restore
//  as they did.
//
//  The reply is the one quoted in the review's RUN.md. Every value is
//  invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class PseudonymBoundaryRestoreTests: XCTestCase {

    static let original = """
    Jordan Ellis signed for Willowcrest Studio LLC. Call +1 (212) 555-0142. \
    See https://example.com/team and case 1:24-cv-01234.
    """

    private func spans(_ text: String, _ items: [(String, EntityType)]) -> [Span] {
        items.map { value, type in
            let range = (text as NSString).range(of: value)
            return Span(start: range.location, end: NSMaxRange(range), type: type, text: value,
                        source: .deterministic, confidence: 1, priority: 50)
        }.sorted { $0.start < $1.start }
    }

    private func mapping() -> Mapping {
        Tokenizer.tokenize(
            text: Self.original,
            spans: spans(Self.original, [
                ("Jordan Ellis", .person), ("Willowcrest Studio LLC", .company), ("+1 (212) 555-0142", .phone),
                ("https://example.com/team", .url), ("1:24-cv-01234", .caseNumber),
            ]),
            sourceFile: "probe.txt",
            createdAtISO8601: "2026-11-11T00:00:00Z",
            style: .pseudonym
        ).mapping
    }

    private func replacement(for value: String, in mapping: Mapping) throws -> String {
        try XCTUnwrap(mapping.entries.values.first { $0.value == value }?.token)
    }

    func testThePseudonymsInTheReviewsReplyRestoreOnlyWhereTheyStandAlone() throws {
        let mapping = mapping()
        let person = try replacement(for: "Jordan Ellis", in: mapping)
        let company = try replacement(for: "Willowcrest Studio LLC", in: mapping)
        let phone = try replacement(for: "+1 (212) 555-0142", in: mapping)
        let url = try replacement(for: "https://example.com/team", in: mapping)
        XCTAssertEqual([person, company, phone], ["Person A", "Company A", "Phone 1"], "the review's pseudonyms")

        let reply = """
        Summary: \(person) signed with \(company). Any Person Acting in Concert with the buyer must disclose it. \
        The Company Assets list and Company Act filings are attached. See \(url) and \(url)2 of the schedule; \
        \(phone) is the main line and the iPhone 15 is excluded.
        """
        let restored = Restorer.restore(text: reply, mapping: mapping)

        XCTAssertTrue(restored.text.contains("Jordan Ellis signed with Willowcrest Studio LLC."), restored.text)
        XCTAssertTrue(restored.text.contains("Any Person Acting in Concert"), restored.text)
        XCTAssertTrue(restored.text.contains("The Company Assets list and Company Act filings"), restored.text)
        XCTAssertTrue(restored.text.contains("See https://example.com/team and \(url)2 of the schedule"), restored.text)
        XCTAssertTrue(restored.text.contains("+1 (212) 555-0142 is the main line and the iPhone 15 is excluded"), restored.text)
        XCTAssertEqual(restored.restoredCount, 4)
        XCTAssertTrue(restored.suspectPlaceholders.contains("\(url)2"), "\(restored.suspectPlaceholders)")
        XCTAssertTrue(restored.suspectPlaceholders.contains("iPhone 15"), "\(restored.suspectPlaceholders)")
        XCTAssertFalse(restored.suspectPlaceholders.contains { $0.contains("Acting") || $0.contains("Assets") },
                       "ordinary words are not flagged: \(restored.suspectPlaceholders)")
    }

    func testALongerPseudonymIsNotFlaggedForTheShorterOneInsideIt() {
        let text = "Item 1 and Item 12."
        let mapping = Mapping(entries: [
            "Item 1": MappingEntry(token: "Item 1", value: "first value", type: .url, surfaceText: "first value", aliases: [], gluedSites: []),
            "Item 12": MappingEntry(token: "Item 12", value: "twelfth value", type: .url, surfaceText: "twelfth value", aliases: [], gluedSites: []),
        ], createdAtISO8601: "2026-11-11T00:00:00Z", sourceFile: "x.txt", style: .pseudonym)
        let restored = Restorer.restore(text: text, mapping: mapping)
        XCTAssertEqual(restored.text, "first value and twelfth value.")
        XCTAssertTrue(restored.suspectPlaceholders.isEmpty, "\(restored.suspectPlaceholders)")
    }

    func testAChinesePseudonymRestoresBetweenChineseCharactersButNotInsideALongerOne() {
        let mapping = Mapping(entries: [
            "张某": MappingEntry(token: "张某", value: "王小明", type: .person, surfaceText: "王小明", aliases: [], gluedSites: []),
            "某电话1": MappingEntry(token: "某电话1", value: "13800138000", type: .phone, surfaceText: "13800138000", aliases: [], gluedSites: []),
        ], createdAtISO8601: "2026-11-11T00:00:00Z", sourceFile: "x.txt", style: .pseudonym)
        let restored = Restorer.restore(text: "张某签字，张某某见证；联系某电话1或某电话12。", mapping: mapping)
        XCTAssertEqual(restored.text, "王小明签字，张某某见证；联系13800138000或某电话12。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.suspectPlaceholders.contains("张某某"), "\(restored.suspectPlaceholders)")
        XCTAssertTrue(restored.suspectPlaceholders.contains("某电话12"), "\(restored.suspectPlaceholders)")
    }

    // MARK: - A document's own touched sites

    private func everySpan(_ text: String, _ value: String, _ type: EntityType) -> [Span] {
        let ns = text as NSString
        var spans: [Span] = []
        var location = 0
        while location < ns.length {
            let range = ns.range(of: value, options: .literal, range: NSRange(location: location, length: ns.length - location))
            guard range.location != NSNotFound else { break }
            spans.append(Span(start: range.location, end: NSMaxRange(range), type: type, text: value,
                              source: .deterministic, confidence: 1, priority: 50))
            location = NSMaxRange(range)
        }
        return spans
    }

    func testADocumentThatWritesAValueAgainstALetterOrDigitStillRestoresToItself() throws {
        let latin = "See the letter signed byMarek Okafor2 on file. Marek Okafor agreed."
        let latinRun = Tokenizer.tokenize(
            text: latin, spans: everySpan(latin, "Marek Okafor", .person),
            sourceFile: "a.txt", createdAtISO8601: "2026-11-11T00:00:00Z", style: .pseudonym
        )
        XCTAssertEqual(latinRun.tokenizedText, "See the letter signed byPerson A2 on file. Person A agreed.")
        XCTAssertEqual(latinRun.mapping.entries["Person A"]?.gluedSites, ["byPerson A2"])
        let latinBack = Restorer.restore(text: latinRun.tokenizedText, mapping: latinRun.mapping)
        XCTAssertEqual(latinBack.text, latin)
        XCTAssertEqual(latinBack.restoredCount, 2)
        XCTAssertTrue(latinBack.suspectPlaceholders.isEmpty, "\(latinBack.suspectPlaceholders)")

        // An AI reply that glues the pseudonym somewhere else is not restored there.
        let reply = Restorer.restore(text: "Person A signed; see thePerson A file.", mapping: latinRun.mapping)
        XCTAssertEqual(reply.text, "Marek Okafor signed; see thePerson A file.")
        XCTAssertEqual(reply.suspectPlaceholders, ["thePerson A"])

        let chinese = "送达地址：北京市朝阳区建国路1号A座。"
        let chineseRun = Tokenizer.tokenize(
            text: chinese, spans: everySpan(chinese, "北京市朝阳区建国路1号", .address),
            sourceFile: "b.txt", createdAtISO8601: "2026-11-11T00:00:00Z", style: .pseudonym
        )
        XCTAssertEqual(chineseRun.tokenizedText, "送达地址：某地址AA座。")
        XCTAssertEqual(Restorer.restore(text: chineseRun.tokenizedText, mapping: chineseRun.mapping).text, chinese)

        // The record survives the sidecar.
        let decoded = try JSONDecoder().decode(Mapping.self, from: JSONEncoder().encode(latinRun.mapping))
        XCTAssertEqual(decoded.entries["Person A"]?.gluedSites, ["byPerson A2"])
        XCTAssertEqual(Restorer.restore(text: latinRun.tokenizedText, mapping: decoded).text, latin)
    }

    func testAnEntryWrittenBeforeTheRecordKeepsTheSubstringMatch() throws {
        // A 2.0 sidecar: no gluedSites. Its own documents may hold touched
        // sites nobody recorded (某地址A written before A座), so it restores
        // as it always did.
        let legacy = Data(
            #"{"entries":{"某地址A":{"aliases":[],"surfaceText":"北京市朝阳区建国路1号","token":"某地址A","type":"ADDRESS","value":"北京市朝阳区建国路1号"}},"createdAtISO8601":"2026-10-01T00:00:00Z","sourceFile":"old.txt","style":"pseudonym"}"#.utf8
        )
        let mapping = try JSONDecoder().decode(Mapping.self, from: legacy)
        XCTAssertNil(mapping.entries["某地址A"]?.gluedSites)
        let restored = Restorer.restore(text: "送达地址：某地址AA座。", mapping: mapping)
        XCTAssertEqual(restored.text, "送达地址：北京市朝阳区建国路1号A座。")
        XCTAssertEqual(restored.restoredCount, 1)
    }
}
