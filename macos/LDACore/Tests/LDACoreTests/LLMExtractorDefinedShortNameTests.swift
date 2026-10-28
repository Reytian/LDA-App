//
//  LLMExtractorDefinedShortNameTests.swift
//  LDACoreTests
//
//  A quoted short name that abbreviates a name the model also reported is
//  that name's short form, and must stay redactable wherever the contract
//  defines it. LLMExtractor.locate used to drop it as generic document
//  vocabulary whenever DefinedTermScanner judged the definition generic, and
//  the scanner does that when the full name starts more than 90 UTF-16 code
//  units before the "(" (an address or registration details in between), or
//  when the words right before the "(" are boilerplate ("a Delaware
//  corporation", "an individual", the "P" of "L.P.", "plc"). The model had
//  tagged every mention; LDA left all of them in clear and reported nothing,
//  because a dropped value never reaches the locator.
//
//  The fixtures are synthetic party clauses, each paired with the values the
//  bundled LDA V4 tagger reported for it (keep labels omitted, as
//  LDAV4Extractor omits them), so each test replays exactly what the tagger
//  hands the locator. The generic terms are reported as COMPANY even though
//  the tagger did not report them, the way an LLM tier over-reports defined
//  terms, to show that they stay readable.
//
//  House rules: all comments and strings in English (fixtures may contain
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LLMExtractorDefinedShortNameTests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// One synthetic text and what the tagger reported for it.
    private struct Probe {
        let name: String
        let text: String
        /// The reported values, in report order.
        let reported: [ExtractedEntity]
        /// Every short name the output must hide, with how often the text
        /// mentions it as a whole word (copies inside a full name included).
        let shortNames: [(surface: String, mentions: Int)]
    }

    private static func company(_ value: String) -> ExtractedEntity {
        ExtractedEntity(value: value, type: .company)
    }

    private static func person(_ value: String) -> ExtractedEntity {
        ExtractedEntity(value: value, type: .person)
    }

    private static func address(_ value: String) -> ExtractedEntity {
        ExtractedEntity(value: value, type: .address)
    }

    /// The batch smoke test's NDA: each short name is defined after its
    /// party's address, well over 90 code units after the full name.
    private static let nda = Probe(
        name: "nda",
        text: [
            "MUTUAL NON-DISCLOSURE AGREEMENT",
            #"This Mutual Non-Disclosure Agreement (the "Agreement") is entered into on March 3, 2026 by and "#
                + #"between Brightwater Analytics LLC, a Delaware limited liability company with its principal "#
                + #"office at 4180 Larkspur Avenue, Suite 210, Portland, Oregon 97205 ("Brightwater"), and "#
                + #"Harrowgate Logistics Ltd., a company incorporated in England with its registered office at "#
                + #"27 Fenwick Lane, Leeds LS1 4QT ("Harrowgate")."#,
            "1. Contacts. Notices to Brightwater shall be sent to Ms. Elena Marquez, General Counsel, at "
                + "elena.marquez@brightwater-analytics.example or +1 (503) 555-0187. Notices to Harrowgate "
                + "shall be sent to Mr. Thomas Okafor at t.okafor@harrowgate-logistics.example.",
            "2. Payment. Harrowgate shall pay Brightwater a fee of USD 48,500 within thirty (30) days.",
            "3. Governing Law. This Agreement is governed by the laws of the State of New York, and the "
                + "parties submit to the courts of New York County.",
            "IN WITNESS WHEREOF:\nElena Marquez, for Brightwater Analytics LLC\n"
                + "Thomas Okafor, for Harrowgate Logistics Ltd.\n"
        ].joined(separator: "\n\n"),
        reported: [
            company("Brightwater Analytics LLC"),
            address("4180 Larkspur Avenue, Suite 210, Portland, Oregon 97205"),
            company("Brightwater"),
            company("Harrowgate Logistics Ltd."),
            address("27 Fenwick Lane, Leeds LS1 4QT"),
            company("Harrowgate"),
            person("Ms. Elena Marquez"),
            company("brightwater-analytics"),
            person("Mr. Thomas Okafor"),
            company("harrowgate-logistics"),
            person("Elena Marquez"),
            person("Thomas Okafor")
        ],
        shortNames: [("Brightwater", 5), ("Harrowgate", 5)]
    )

    /// The full name starts exactly 90 code units before the "(": the last
    /// distance the scanner's window still reads as an alias.
    private static let gap90 = Probe(
        name: "gap_90",
        text: #"This Agreement is made between Brightwater Analytics LLC, a Delaware limited liability company "#
            + #"with its office in Eugene ("Brightwater"). Brightwater shall pay the fee."#,
        reported: [company("Brightwater Analytics LLC"), company("Brightwater")],
        shortNames: [("Brightwater", 3)]
    )

    /// One code unit further ("Medford" for "Eugene"): the scanner now reads
    /// the definition as generic.
    private static let gap91 = Probe(
        name: "gap_91",
        text: #"This Agreement is made between Brightwater Analytics LLC, a Delaware limited liability company "#
            + #"with its office in Medford ("Brightwater"). Brightwater shall pay the fee."#,
        reported: [company("Brightwater Analytics LLC"), company("Brightwater")],
        shortNames: [("Brightwater", 3)]
    )

    /// An English parties block: registration details between each name and
    /// its definition, and full names in capitals.
    private static let ukParties = Probe(
        name: "uk_parties",
        text: [
            "THIS AGREEMENT is dated 3 March 2026 and is made between:",
            #"(1) HARROWGATE LOGISTICS LIMITED, a company incorporated in England and Wales with company "#
                + #"number 01234567 whose registered office is at 27 Fenwick Lane, Leeds LS1 4QT ("Harrowgate"); and"#,
            #"(2) BRIGHTWATER ANALYTICS LLC, a Delaware limited liability company whose principal office is "#
                + #"at 4180 Larkspur Avenue, Portland, Oregon 97205 ("Brightwater")."#,
            "Harrowgate shall provide the services to Brightwater."
        ].joined(separator: "\n"),
        reported: [
            company("HARROWGATE LOGISTICS LIMITED"),
            address("27 Fenwick Lane, Leeds LS1 4QT"),
            company("Harrowgate"),
            company("BRIGHTWATER ANALYTICS LLC"),
            address("4180 Larkspur Avenue, Portland, Oregon 97205"),
            company("Brightwater")
        ],
        shortNames: [("Harrowgate", 2), ("Brightwater", 2)]
    )

    /// The party's description ends right before the "(", and the scanner's
    /// boilerplate test reads it in place of the name: "corporation",
    /// "company", a country, a state, the one-letter "P" of "L.P.", the
    /// lowercase "plc", "individual".
    private static let boilerplateTails: [Probe] = [
        Probe(
            name: "tail_corporation",
            text: #"This Agreement is made between Brightwater Analytics Inc., a Delaware corporation "#
                + #"("Brightwater"), and Lumen Data Ltd. (hereinafter "Lumen"). Brightwater shall pay Lumen the fee."#,
            reported: [
                company("Brightwater Analytics Inc."), company("Brightwater"),
                company("Lumen Data Ltd."), company("Lumen")
            ],
            shortNames: [("Brightwater", 3), ("Lumen", 3)]
        ),
        Probe(
            name: "tail_company",
            text: #"This Agreement is made between Brightwater Analytics LLC, a Delaware limited liability company "#
                + #"("Brightwater"), and Lumen Data Ltd. (hereinafter "Lumen"). Brightwater shall pay Lumen the fee."#,
            reported: [
                company("Brightwater Analytics LLC"), company("Brightwater"),
                company("Lumen Data Ltd."), company("Lumen")
            ],
            shortNames: [("Brightwater", 3), ("Lumen", 3)]
        ),
        Probe(
            name: "tail_country",
            text: #"This Agreement is made between Harrowgate Logistics Ltd., a company incorporated in England "#
                + #"("Harrowgate"), and Lumen Data Ltd. (hereinafter "Lumen"). Harrowgate shall pay Lumen the fee."#,
            reported: [
                company("Harrowgate Logistics Ltd."), company("Harrowgate"),
                company("Lumen Data Ltd."), company("Lumen")
            ],
            shortNames: [("Harrowgate", 3), ("Lumen", 3)]
        ),
        Probe(
            name: "tail_state",
            text: #"This Agreement is made between Brightwater Analytics LLC of Portland, Oregon ("Brightwater") "#
                + #"and Lumen Data Ltd. (hereinafter "Lumen"). Brightwater shall pay Lumen the fee."#,
            reported: [
                company("Brightwater Analytics LLC"), company("Brightwater"),
                company("Lumen Data Ltd."), company("Lumen")
            ],
            shortNames: [("Brightwater", 3), ("Lumen", 3)]
        ),
        Probe(
            name: "tail_lp",
            text: #"This Agreement is made between Brightwater Capital Partners, L.P. ("Brightwater") "#
                + #"and Lumen Data Ltd. (hereinafter "Lumen"). Brightwater shall pay Lumen the fee."#,
            reported: [
                company("Brightwater Capital Partners, L.P."), company("Brightwater"),
                company("Lumen Data Ltd."), company("Lumen")
            ],
            shortNames: [("Brightwater", 3), ("Lumen", 3)]
        ),
        Probe(
            name: "tail_plc",
            text: #"This Agreement is made between Harrowgate Logistics plc ("Harrowgate") "#
                + #"and Lumen Data Ltd. (hereinafter "Lumen"). Harrowgate shall pay Lumen the fee."#,
            reported: [
                company("Harrowgate Logistics plc"), company("Harrowgate"),
                company("Lumen Data Ltd."), company("Lumen")
            ],
            shortNames: [("Harrowgate", 3), ("Lumen", 3)]
        ),
        Probe(
            name: "tail_individual",
            text: #"This Consulting Agreement is made between Harrowgate Logistics Ltd. ("Harrowgate") "#
                + #"and Ms. Elena Marquez, an individual ("Marquez"). Marquez shall report to Harrowgate."#,
            reported: [
                company("Harrowgate Logistics Ltd."), company("Harrowgate"),
                person("Ms. Elena Marquez"), person("Marquez")
            ],
            shortNames: [("Marquez", 3), ("Harrowgate", 3)]
        )
    ]

    /// A person's short name defined after a residence address.
    private static let personAlias = Probe(
        name: "person_alias",
        text: #"This Consulting Agreement is made between Harrowgate Logistics Ltd. ("Harrowgate") and "#
            + #"Ms. Elena Marquez, an individual residing at 902 Alder Street, Apartment 4B, Seattle, "#
            + #"Washington 98101 ("Marquez"). Marquez shall report to Harrowgate."#,
        reported: [
            company("Harrowgate Logistics Ltd."),
            company("Harrowgate"),
            person("Ms. Elena Marquez"),
            address("902 Alder Street, Apartment 4B, Seattle, Washington 98101"),
            person("Marquez")
        ],
        shortNames: [("Marquez", 3), ("Harrowgate", 3)]
    )

    /// A bare-quote Chinese short name that skips characters of the full
    /// name (蓝鲸科技 from 蓝鲸智能科技有限公司), next to the 以下简称 form the
    /// scanner never drops.
    private static let zhBareQuote = Probe(
        name: "zh_bare_quote",
        text: "甲方：蓝鲸智能科技有限公司（\u{201C}蓝鲸科技\u{201D}），"
            + "乙方：星辰数据服务有限公司（以下简称\u{201C}星辰数据\u{201D}）。蓝鲸科技应向星辰数据支付服务费。",
        reported: [
            company("蓝鲸智能科技有限公司"),
            company("蓝鲸科技"),
            company("星辰数据服务有限公司"),
            company("星辰数据")
        ],
        shortNames: [("蓝鲸科技", 2), ("星辰数据", 3)]
    )

    /// Definitions right after the full name, which the scanner reads as
    /// aliases already.
    private static let adjacent = Probe(
        name: "adjacent",
        text: #"This Agreement is made between Brightwater Analytics LLC ("Brightwater") and "#
            + #"Harrowgate Logistics Ltd. ("Harrowgate"). Harrowgate shall pay Brightwater the fee."#,
        reported: [
            company("Brightwater Analytics LLC"), company("Brightwater"),
            company("Harrowgate Logistics Ltd."), company("Harrowgate")
        ],
        shortNames: [("Brightwater", 3), ("Harrowgate", 3)]
    )

    // MARK: - Helpers

    /// Every case-sensitive occurrence of `surface` in `text`, as UTF-16
    /// ranges. A Latin surface must stand as a whole word; a CJK surface has no
    /// word boundaries to respect.
    private func mentions(of surface: String, in text: String) -> [NSRange] {
        let escaped = NSRegularExpression.escapedPattern(for: surface)
        let pattern = DefinedTermScanner.containsCJK(surface)
            ? escaped
            : "(?<![\\p{L}\\p{N}])" + escaped + "(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            XCTFail("cannot search for \(surface)")
            return []
        }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range)
    }

    /// Runs the probe's report through the locator, the way LDAV4Extractor
    /// does, and fails for every short-name mention no span covers.
    private func assertShortNamesHidden(
        _ probe: Probe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let spans = LLMExtractor.locate(probe.reported, in: probe.text, incompleteSegmentCount: 0).spans
        for (surface, count) in probe.shortNames {
            let found = mentions(of: surface, in: probe.text)
            XCTAssertEqual(
                found.count, count,
                "\(probe.name): the fixture should mention \(surface) \(count) times",
                file: file, line: line
            )
            let readable = found.filter { mention in
                !spans.contains { $0.start <= mention.location && $0.end >= NSMaxRange(mention) }
            }
            XCTAssertTrue(
                readable.isEmpty,
                "\(probe.name): \(readable.count) of \(found.count) mentions of \(surface) are left in clear",
                file: file, line: line
            )
        }
    }

    /// Fails when any span touches a mention of `term`: a generic defined
    /// term must stay readable.
    private func assertReadable(
        _ term: String,
        in text: String,
        spans: [Span],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let found = mentions(of: term, in: text)
        XCTAssertFalse(found.isEmpty, "the fixture should mention \(term)", file: file, line: line)
        for mention in found where spans.contains(where: {
            $0.start < NSMaxRange(mention) && $0.end > mention.location
        }) {
            XCTFail("\(term) at \(mention.location) is redacted", file: file, line: line)
        }
    }

    // MARK: - Short names the defined-term filter used to drop

    func testShortNamesDefinedAfterTheirPartysAddressAreHidden() {
        assertShortNamesHidden(Self.nda)
    }

    func testShortNameDefinedOneCodeUnitPastTheScannerWindowIsHidden() {
        assertShortNamesHidden(Self.gap91)
    }

    func testShortNamesOfAPartiesBlockWithRegistrationDetailsAreHidden() {
        assertShortNamesHidden(Self.ukParties)
    }

    func testShortNameAfterABoilerplateDescriptionOfItsPartyIsHidden() {
        for probe in Self.boilerplateTails {
            assertShortNamesHidden(probe)
        }
    }

    func testPersonShortNameDefinedAfterAResidenceAddressIsHidden() {
        assertShortNamesHidden(Self.personAlias)
    }

    func testChineseBareQuoteShortNameThatSkipsCharactersIsHidden() {
        assertShortNamesHidden(Self.zhBareQuote)
    }

    // MARK: - Short names the scanner already reads as aliases

    func testShortNamesTheScannerReadsAsAliasesStayHidden() {
        assertShortNamesHidden(Self.gap90)
        assertShortNamesHidden(Self.adjacent)
    }

    // MARK: - Generic defined terms stay readable

    func testRoleTermsStayReadableWhenAModelReportsThem() {
        let text = #"This Supply Agreement (the "Agreement") is made between Brightwater Analytics LLC "#
            + #"(the "Company") and Harrowgate Logistics Ltd. (the "Supplier"). The Company shall pay the Supplier."#
        let reported = [
            Self.company("Brightwater Analytics LLC"),
            Self.company("Agreement"),
            Self.company("Company"),
            Self.company("Harrowgate Logistics Ltd."),
            Self.company("Supplier")
        ]

        let spans = LLMExtractor.locate(reported, in: text, incompleteSegmentCount: 0).spans

        XCTAssertEqual(Set(spans.map(\.text)), ["Brightwater Analytics LLC", "Harrowgate Logistics Ltd."])
        for term in ["Agreement", "Company", "Supplier"] {
            assertReadable(term, in: text, spans: spans)
        }
    }

    func testAGenericDefinedTermThatAbbreviatesNoReportedNameStaysReadable() {
        // "Platform" is not boilerplate, so the document's own defined-term
        // vocabulary is what drops it. No name in the report contains it, so
        // keeping short names must not keep it.
        let text = #"Lumen Data Ltd. (hereinafter "Lumen") licenses the analytics software described in "#
            + #"Schedule 1 (the "Platform") to Brightwater Analytics LLC ("Brightwater"). Brightwater may use "#
            + #"the Platform, and Lumen shall host the Platform."#
        let reported = [
            Self.company("Lumen Data Ltd."),
            Self.company("Lumen"),
            Self.company("Platform"),
            Self.company("Brightwater Analytics LLC"),
            Self.company("Brightwater")
        ]

        let spans = LLMExtractor.locate(reported, in: text, incompleteSegmentCount: 0).spans

        assertReadable("Platform", in: text, spans: spans)
        XCTAssertTrue(spans.contains { $0.text == "Brightwater" })
        XCTAssertTrue(spans.contains { $0.text == "Lumen" })
    }

    // MARK: - The scanner itself is unchanged (regression baseline)

    /// The fix lives in the locator, not in the scanner: the scanner still
    /// reads gap_90's definition as an alias and gap_91's as generic. If its
    /// window ever changes, this pins the old boundary so the change is a
    /// deliberate one.
    func testTheScannerWindowStillEndsNinetyCodeUnitsBeforeTheDefinition() {
        for (probe, distance) in [(Self.gap90, 90), (Self.gap91, 91)] {
            let ns = probe.text as NSString
            XCTAssertEqual(
                ns.range(of: #"("Brightwater")"#).location - ns.range(of: "Brightwater Analytics LLC").location,
                distance,
                "\(probe.name): code units from the full name to the definition"
            )
        }
        XCTAssertFalse(DefinedTermScanner.droppableTerms(in: Self.gap90.text).contains("brightwater"))
        XCTAssertEqual(DefinedTermScanner.aliasBindings(in: Self.gap90.text).map(\.alias), ["Brightwater"])
        XCTAssertTrue(DefinedTermScanner.droppableTerms(in: Self.gap91.text).contains("brightwater"))
        XCTAssertEqual(DefinedTermScanner.aliasBindings(in: Self.gap91.text).map(\.alias), [])
    }

    // MARK: - End to end: the anonymized output

    /// Returns one canned completion for every prompt.
    private struct FixedCompleter: TextCompleter {
        let output: String

        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            output
        }
    }

    /// The smoke test's failure, through the whole facade: detection, merge,
    /// rescan and substitution. The fake model reports what LDA V4 reported
    /// for the NDA; the redacted output must not carry any party name, short
    /// or full.
    func testAnonymizedNDALeavesNoPartyNameInClear() throws {
        let rows = Self.nda.reported.map { ["value": $0.value, "type": $0.type.rawValue] }
        let completion = String(
            decoding: try JSONSerialization.data(withJSONObject: ["entities": rows]),
            as: UTF8.self
        )
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: completion))
        }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefinedShortNameTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }
        let input = workDir.appendingPathComponent("nda.txt")
        try Data(Self.nda.text.utf8).write(to: input)

        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("correct horse battery staple"),
            createdAtISO8601: "2026-10-28T00:00:00Z",
            llmModelPath: "/nonexistent.gguf"
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8).lowercased()
        for name in ["brightwater", "harrowgate", "marquez", "okafor"] {
            XCTAssertFalse(redacted.contains(name), "\(name) is readable in the redacted output")
        }
    }
}
