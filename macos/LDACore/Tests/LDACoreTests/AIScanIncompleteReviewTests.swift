//
//  AIScanIncompleteReviewTests.swift
//  LDACoreTests
//
//  How Review reports an AI pass that ran but did not finish the job.
//
//  LDA 1.3 showed "AI did not run" for every AI warning, including a pass
//  that ran in full and reported two values it could not anchor. The model
//  had run, the headline said otherwise, and the warning counted the values
//  without naming them, so the user could not find what was left in the
//  document. These tests pin the three headline states, the list of values
//  the pass could not remove, where each of them is still written, and that
//  Protect redacts exactly those places and nothing else.
//
//  Deterministic detection plus a test completer; no model is needed.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class AIScanIncompleteReviewTests: XCTestCase {

    private var workDir: URL!

    /// "Jordan Lee" runs into the digit after it, so the locator refuses its
    /// edge and the value stays in the document. "Northwind Traders" anchors.
    private static let glued = "Signed by Jordan Lee2 for Northwind Traders on 3 May."
    private static let gluedName = NSRange(location: 10, length: 10)

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIScanIncompleteReviewTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ReviewModel.llmExtractorFactoryForTesting = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// Reports both parties of the glued fixture.
    private struct ReportsBothParties: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            #"{"entities":[{"value":"Jordan Lee","type":"PERSON"},{"value":"Northwind Traders","type":"COMPANY"}],"redacted_text":""}"#
        }
    }

    /// Reports only the party that anchors, so the pass is clean.
    private struct ReportsOnlyTheCompany: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            #"{"entities":[{"value":"Northwind Traders","type":"COMPANY"}],"redacted_text":""}"#
        }
    }

    /// Reports one value, as the given type.
    private struct ReportsOne: TextCompleter {
        let value: String
        let type: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            #"{"entities":[{"value":"\#(value)","type":"\#(type)"}],"redacted_text":""}"#
        }
    }

    /// Every completion fails: the backend never answers.
    private struct NeverAnswers: TextCompleter {
        struct Down: Error {}
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            throw Down()
        }
    }

    /// Blocks until the run's cancel token fires, then reports the stop.
    private final class BlockingUntilCancelled: TextCompleter, CancelAwareCompleter {
        var cancelToken: ExtractionCancelToken?
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            while cancelToken?.isCancelled != true {
                Thread.sleep(forTimeInterval: 0.005)
            }
            throw LLMEngine.LLMError.cancelled
        }
    }

    private func write(_ text: String, named name: String = "synthetic.txt") throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func writeDummyModel() throws -> URL {
        let url = workDir.appendingPathComponent("dummy.gguf")
        try Data("synthetic".utf8).write(to: url)
        return url
    }

    /// A model that has scanned `text` with a pass whose completer answers
    /// every segment with `completer`.
    private func scanned(_ text: String, with completer: TextCompleter) async throws -> ReviewModel {
        let model = ReviewModel(modelPath: try writeDummyModel().path)
        ReviewModel.llmExtractorFactoryForTesting = { _, cancel in
            LLMExtractor(completer: completer, cancelToken: cancel)
        }
        await model.open(try write(text))
        await model.anonymize()
        return model
    }

    /// A model that has scanned the glued fixture with a pass that reports
    /// both parties.
    private func scannedGluedDocument() async throws -> ReviewModel {
        try await scanned(Self.glued, with: ReportsBothParties())
    }

    private func gate(_ model: ReviewModel) -> ModelSetupPresentation.ExportGateReason? {
        ModelSetupPresentation.exportGateReason(documents: [
            (model.exportAvailability.isAvailable, model.aiActive, model.aiWarning, model.aiRanPartially)
        ])
    }

    private func covers(_ entity: ReviewEntity, _ range: NSRange) -> Bool {
        entity.span.start <= range.location && entity.span.end >= NSMaxRange(range)
    }

    // MARK: - The headline names each state

    func testTheHeadlineNamesEachOfTheThreeStatesAndNothingForACleanPass() {
        XCTAssertNil(
            AIScanHeadline(AIScanCoverage(aiActive: true, aiWarning: nil, aiRanPartially: false)),
            "a pass that ran to full coverage carries no headline"
        )

        let patternsOnly = AIScanHeadline(
            AIScanCoverage(aiActive: false, aiWarning: nil, aiRanPartially: false)
        )
        XCTAssertEqual(patternsOnly, .patternsOnly)
        XCTAssertEqual(patternsOnly?.titleKey, "Patterns only")
        XCTAssertEqual(patternsOnly?.isWarning, false, "a deliberate choice is information, not a warning")

        let didNotRun = AIScanHeadline(
            AIScanCoverage(aiActive: false, aiWarning: "no model", aiRanPartially: false)
        )
        XCTAssertEqual(didNotRun, .didNotRun)
        XCTAssertEqual(didNotRun?.titleKey, "AI did not run")
        XCTAssertEqual(didNotRun?.isWarning, true)

        let ranPartially = AIScanHeadline(
            AIScanCoverage(aiActive: false, aiWarning: "2 values not located", aiRanPartially: true)
        )
        XCTAssertEqual(ranPartially, .ranPartially)
        XCTAssertEqual(
            ranPartially?.titleKey, "AI scan incomplete",
            "a pass that ran must not be titled as one that did not"
        )
        XCTAssertEqual(ranPartially?.isWarning, true, "it keeps the red warning style")
        XCTAssertEqual(ranPartially?.systemImage, didNotRun?.systemImage)
    }

    func testTheHeadlineReadsTheSameStateAsTheExportGateAndTheWorkspaceRecord() {
        // No warning means no AI pass was asked for, whatever the partial
        // flag says; the gate reads it the same way.
        XCTAssertEqual(
            AIScanHeadline(AIScanCoverage(aiActive: false, aiWarning: nil, aiRanPartially: true)),
            .patternsOnly
        )
        for (coverage, reason) in [
            (AIScanCoverage(aiActive: false, aiWarning: "no model", aiRanPartially: false),
             ModelSetupPresentation.ExportGateReason.didNotRun),
            (AIScanCoverage(aiActive: false, aiWarning: "stopped short", aiRanPartially: true),
             .ranPartially)
        ] {
            let gateReason = ModelSetupPresentation.exportGateReason(documents: [
                (true, coverage.aiActive, coverage.aiWarning, coverage.aiRanPartially)
            ])
            XCTAssertEqual(gateReason, reason)
            XCTAssertEqual(
                AIScanHeadline(coverage),
                reason == .ranPartially ? .ranPartially : .didNotRun,
                "the banner and the gate must describe one pass the same way"
            )
        }
        // Every shape of the three fields: the headline is the record's image.
        for aiActive in [false, true] {
            for aiWarning in [nil, "warning"] as [String?] {
                for aiRanPartially in [false, true] {
                    let coverage = AIScanCoverage(aiActive: aiActive, aiWarning: aiWarning, aiRanPartially: aiRanPartially)
                    let expected: AIScanHeadline?
                    switch coverage.workspaceRecord {
                    case .complete: expected = nil
                    case .notRequested: expected = .patternsOnly
                    case .didNotRun: expected = .didNotRun
                    case .ranPartially: expected = .ranPartially
                    }
                    XCTAssertEqual(AIScanHeadline(coverage), expected, "\(coverage)")
                }
            }
        }
    }

    func testEveryHeadlineHasItsOwnTitleInEveryShippedLanguage() throws {
        for identifier in Self.catalogIdentifiers {
            let catalog = try Self.catalog(identifier)
            var titles: [String] = []
            for headline in AIScanHeadline.allCases {
                let title = try XCTUnwrap(
                    catalog[headline.titleKey],
                    "\(identifier) has no entry for \(headline.titleKey)"
                )
                XCTAssertFalse(title.trimmingCharacters(in: .whitespaces).isEmpty)
                titles.append(title)
            }
            XCTAssertEqual(
                Set(titles).count, titles.count,
                "\(identifier): the three states must read differently: \(titles)"
            )
            if identifier.hasPrefix("zh") {
                for title in titles {
                    XCTAssertTrue(
                        title.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                        "\(identifier) title reads as English: \(title)"
                    )
                }
            }
        }
        XCTAssertEqual(
            L10n.string("AI scan incomplete", language: .french),
            "Analyse par IA incomplète"
        )
        XCTAssertEqual(L10n.string("AI scan incomplete", language: .simplifiedChinese), "AI 扫描未完成")
        XCTAssertEqual(L10n.string("AI scan incomplete", language: .traditionalChinese), "AI 掃描未完成")
    }

    func testTheBannerTakesItsTitleFromTheHeadline() throws {
        // The 1.3 banner hard-coded "AI did not run" for every warning. The
        // title now comes from AIScanHeadline, so the partial state cannot
        // fall back to it again without this failing.
        let banner = try Self.uiSource("AppShellStatusBanner.swift")
        XCTAssertTrue(banner.contains("AIScanHeadline(model.aiCoverage)"))
        XCTAssertEqual(
            banner.components(separatedBy: "L10n.text(headline.titleKey)").count - 1, 1,
            "one label, built from the headline, serves every state; a second, state-specific title would be a way back to the 1.3 bug"
        )
        for hardCoded in ["\"AI did not run\"", "\"AI scan incomplete\"", ".didNotRun.titleKey", ".ranPartially.titleKey"] {
            XCTAssertFalse(banner.contains(hardCoded), "the banner must not hard-code a headline: \(hardCoded)")
        }
        XCTAssertTrue(
            banner.contains("UnlocatedValuesPopover("),
            "the values the pass could not remove are listed beside the warning"
        )
        XCTAssertTrue(
            banner.contains("count: model.aiUnlocatedValues.count"),
            "the control counts the values the list shows"
        )
    }

    func testTheListProtectsTheRunInPlacesOfTheRowItShows() throws {
        // The popover is a thin view over the model; what it must not lose is
        // which placement a row's button protects.
        let popover = try Self.uiSource("UnlocatedValuesPopover.swift")
        XCTAssertTrue(popover.contains("ForEach(Array(model.aiUnlocatedPlacements.enumerated())"))
        XCTAssertTrue(popover.contains("model.protectRunIns(of: placement, undoManager: undoManager)"))
        XCTAssertFalse(
            popover.contains("protectValue("),
            "a listed value is never protected by searching for its letters"
        )
    }

    // MARK: - A pass that examined nothing did not run

    func testAPassWhoseEverySegmentFailedSaysTheAIDidNotRun() async throws {
        // 1.3 titled this "AI did not run", correctly; the first fix of the
        // partial headline must not turn it into "AI scan incomplete", which
        // says some names were found.
        let model = try await scanned(Self.glued, with: NeverAnswers())

        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(model.aiActive)
        XCTAssertFalse(model.aiRanPartially, "nothing was examined, so nothing ran partially")
        XCTAssertEqual(
            model.aiWarning,
            L10n.string("AI detection failed to run; this pass was pattern matching only.")
        )
        XCTAssertEqual(AIScanHeadline(model.aiCoverage), .didNotRun)
        XCTAssertEqual(gate(model), .didNotRun)
        XCTAssertTrue(model.aiUnlocatedValues.isEmpty)
    }

    // MARK: - The values the pass could not remove

    func testAPassThatLeavesAValueInPlaceIsPartialAndNamesIt() async throws {
        let model = try await scannedGluedDocument()

        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(model.aiActive)
        XCTAssertTrue(model.aiRanPartially, "the pass ran; it did not finish the job")
        XCTAssertNotNil(model.aiWarning)
        XCTAssertEqual(AIScanHeadline(model.aiCoverage), .ranPartially)
        XCTAssertEqual(gate(model), .ranPartially)
        XCTAssertEqual(
            model.aiUnlocatedValues,
            [ExtractedEntity(value: "Jordan Lee", type: .person)],
            "the value left in the document is named with its type"
        )
        XCTAssertEqual(
            model.aiUnlocatedPlacements.map(\.runIns), [[Self.gluedName]],
            "and where it is written, worked out once when the list is set"
        )
        XCTAssertEqual(AIScanCoveragePresentation.showValuesTitle(count: 1, language: .english), "Show 1 value")
    }

    func testTheWarningStaysTrueOnceTheValuesAreProtected() async throws {
        let model = try await scannedGluedDocument()
        let warning = try XCTUnwrap(model.aiWarning)
        XCTAssertEqual(
            warning,
            String(
                format: L10n.string("AI found %lld value it could not locate exactly in some places, so it was not redacted there. It stays in the document until you protect it."),
                Int64(1)
            ),
            "the warning says what the scan left, not that the value is still in clear after the user protects it"
        )

        let placement = try XCTUnwrap(model.aiUnlocatedPlacements.first)
        XCTAssertFalse(model.allUnlocatedValuesProtected)
        model.protectRunIns(of: placement, undoManager: nil)
        XCTAssertTrue(model.allUnlocatedValuesProtected, "the banner's control shows the list is done")
    }

    func testNothingOnTheListIsRedactedUntilTheUserProtectsIt() async throws {
        let model = try await scannedGluedDocument()
        let placement = try XCTUnwrap(model.aiUnlocatedPlacements.first)

        // Redaction by default is exactly what the pass anchored.
        XCTAssertTrue(
            model.entities.contains { $0.span.text == "Northwind Traders" && $0.accepted },
            "the anchored party is redacted as before"
        )
        XCTAssertFalse(
            model.entities.contains { covers($0, Self.gluedName) },
            "the listed value is not added to the review list on its own"
        )
        XCTAssertEqual(model.protection(of: placement), .exposed(remaining: 1))

        let outcome = model.protectRunIns(of: placement, undoManager: nil)

        XCTAssertNil(outcome.refusal)
        XCTAssertEqual(outcome.added, 1)
        XCTAssertTrue(
            model.entities.contains { $0.accepted && $0.span.type == .person && covers($0, Self.gluedName) },
            "protecting the value covers the place the locator refused"
        )
        XCTAssertEqual(model.protection(of: placement), .protected)
        XCTAssertEqual(
            model.aiUnlocatedValues, [placement.value],
            "the list describes the scan, so it stays until the next scan"
        )
    }

    func testAWrappedRepeatIsProtectedTooAndNeverCalledProtectedWhileInClear() async throws {
        // Review finding: the first version searched the value's exact
        // spelling only, so after Protect covered "Jordan Lee1" the row read
        // Protected while the wrapped "Jordan\nLee2" was still in clear.
        let text = "Signed by Jordan Lee1 for Northwind Traders.\nWitness: Jordan\nLee2."
        let model = try await scanned(text, with: ReportsBothParties())
        let placement = try XCTUnwrap(model.aiUnlocatedPlacements.first)
        XCTAssertEqual(placement.runIns.count, 2)

        model.protectRunIns(of: placement, undoManager: nil)

        XCTAssertEqual(model.protection(of: placement), .protected)
        let wrapped = (text as NSString).range(of: "Jordan\nLee")
        XCTAssertTrue(
            model.entities.contains { $0.accepted && covers($0, wrapped) && $0.span.text == "Jordan\nLee" },
            "the wrapped mention is covered, with the document's own spelling"
        )
    }

    func testANameRedactedOnceAndGluedElsewhereIsListedAndProtectable() async throws {
        // Review finding (predates the list): the first mention anchors and is
        // redacted, and the footnoted repeat was left in clear with nothing
        // said. Now the pass reads as incomplete, the value is listed, and
        // Protect covers the glued mention.
        let text = "Jordan Lee signed for Northwind Traders. Witnessed by Jordan Lee2."
        let model = try await scanned(text, with: ReportsBothParties())

        XCTAssertTrue(model.aiRanPartially)
        XCTAssertEqual(AIScanHeadline(model.aiCoverage), .ranPartially)
        XCTAssertEqual(gate(model), .ranPartially, "Export for AI asks before handing it over")
        XCTAssertTrue(
            model.entities.contains { $0.accepted && $0.span.start == 0 && $0.span.text == "Jordan Lee" },
            "the anchored mention is redacted as before"
        )
        let placement = try XCTUnwrap(model.aiUnlocatedPlacements.first)
        XCTAssertEqual(placement.value, ExtractedEntity(value: "Jordan Lee", type: .person))
        let glued = (text as NSString).range(of: "Jordan Lee2")
        XCTAssertEqual(placement.runIns, [NSRange(location: glued.location, length: 10)])
        XCTAssertEqual(model.protection(of: placement), .exposed(remaining: 1))

        model.protectRunIns(of: placement, undoManager: nil)

        XCTAssertEqual(model.protection(of: placement), .protected)
        XCTAssertTrue(model.entities.contains { $0.accepted && $0.span.start == glued.location })
    }

    func testProtectingAShortValueNeverCutsOrdinaryWords() async throws {
        // Review finding: the first version opened Protect on the first
        // case-insensitive hit, "li" inside "compliance", and the literal
        // search then redacted "li" inside every word that has it.
        let text = "This Agreement is made in compliance with the Limited Liability Act and signed by Mr. Li1."
        let model = try await scanned(text, with: ReportsOne(value: "Li", type: "PERSON"))
        let placement = try XCTUnwrap(model.aiUnlocatedPlacements.first)
        let before = Set(model.entities.map(\.id))

        let outcome = model.protectRunIns(of: placement, undoManager: nil)

        XCTAssertEqual(outcome.added, 1)
        let added = model.entities.filter { !before.contains($0.id) }
        XCTAssertEqual(added.map(\.span.text), ["Li"])
        XCTAssertEqual(added.first?.span.start, (text as NSString).range(of: "Li1").location)
        for word in ["compliance", "Limited", "Liability"] {
            let range = (text as NSString).range(of: word)
            XCTAssertFalse(
                added.contains { $0.span.start < NSMaxRange(range) && $0.span.end > range.location },
                "\(word) must not be touched"
            )
        }
        XCTAssertEqual(model.protection(of: placement), .protected)
    }

    func testAValueEndingInPunctuationIsProtectedWhole() async throws {
        // Review finding: the chooser trimmed the closing bracket, so the
        // entity ended one character short and the row could never read
        // Protected.
        let text = "This agreement is made betweenAcme Holdings (BVI) and the buyer."
        let model = try await scanned(text, with: ReportsOne(value: "Acme Holdings (BVI)", type: "COMPANY"))
        let placement = try XCTUnwrap(model.aiUnlocatedPlacements.first)
        XCTAssertEqual(placement.value.type, .company)

        model.protectRunIns(of: placement, undoManager: nil)

        let whole = (text as NSString).range(of: "Acme Holdings (BVI)")
        XCTAssertTrue(model.entities.contains { $0.accepted && $0.span.start == whole.location && $0.span.end == NSMaxRange(whole) })
        XCTAssertEqual(model.protection(of: placement), .protected)
    }

    func testUndoPutsTheListedValueBack() async throws {
        let model = try await scannedGluedDocument()
        let placement = try XCTUnwrap(model.aiUnlocatedPlacements.first)
        let before = model.entities
        let undoManager = UndoManager()

        model.protectRunIns(of: placement, undoManager: undoManager)
        XCTAssertEqual(model.protection(of: placement), .protected)
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        XCTAssertEqual(model.entities, before)
        XCTAssertEqual(model.protection(of: placement), .exposed(remaining: 1))
    }

    func testACancelledRetryKeepsTheNamedValues() async throws {
        let model = try await scannedGluedDocument()
        let before = model.aiCoverage
        let placementsBefore = model.aiUnlocatedPlacements
        XCTAssertFalse(before.unlocatedValues.isEmpty)

        ReviewModel.llmExtractorFactoryForTesting = { _, cancel in
            LLMExtractor(completer: BlockingUntilCancelled(), cancelToken: cancel)
        }
        let run = Task { await model.anonymize() }
        var waited = 0
        while model.status != .detecting && waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertEqual(model.status, .detecting, "the retry never started")
        XCTAssertTrue(model.aiUnlocatedValues.isEmpty, "a running pass lists nothing yet")
        model.cancelAnonymize()
        await run.value

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(
            model.aiCoverage, before,
            "a stopped retry hands back the warning together with its values"
        )
        XCTAssertEqual(model.aiUnlocatedPlacements, placementsBefore, "and where they are written")
    }

    func testACompletedCleanRetryClearsTheNamedValues() async throws {
        let model = try await scannedGluedDocument()
        XCTAssertFalse(model.aiUnlocatedValues.isEmpty)

        ReviewModel.llmExtractorFactoryForTesting = { _, cancel in
            LLMExtractor(completer: ReportsOnlyTheCompany(), cancelToken: cancel)
        }
        await model.anonymize()

        XCTAssertTrue(model.aiActive)
        XCTAssertNil(model.aiWarning)
        XCTAssertTrue(model.aiUnlocatedValues.isEmpty)
        XCTAssertTrue(model.aiUnlocatedPlacements.isEmpty)
        XCTAssertNil(AIScanHeadline(model.aiCoverage))
    }

    func testOpeningAnotherDocumentClearsTheNamedValues() async throws {
        let model = try await scannedGluedDocument()
        XCTAssertFalse(model.aiUnlocatedValues.isEmpty)

        await model.open(try write("A different agreement.", named: "other.txt"))

        XCTAssertTrue(
            model.aiUnlocatedValues.isEmpty,
            "one document's values must never be listed over another"
        )
        XCTAssertTrue(model.aiUnlocatedPlacements.isEmpty)
    }

    func testOpeningAnotherDocumentResetsAllOfTheCoverageAtOnce() async throws {
        let model = try await scanned(Self.glued, with: ReportsOnlyTheCompany())
        XCTAssertTrue(model.aiActive, "a clean pass")

        await model.open(try write("A different agreement.", named: "other.txt"))

        XCTAssertEqual(model.aiCoverage, .unscanned, "no field of the previous scan's coverage survives")
    }

    func testAPassThatNeverRanNamesNothing() async throws {
        let model = ReviewModel(modelPath: nil)
        await model.open(try write(Self.glued))
        await model.anonymize()

        XCTAssertEqual(AIScanHeadline(model.aiCoverage), .didNotRun)
        XCTAssertTrue(model.aiUnlocatedValues.isEmpty)
    }

    func testTheValuesStayOutOfTheWarningAndTheWorkspaceRecord() async throws {
        let model = try await scannedGluedDocument()

        let warning = try XCTUnwrap(model.aiWarning)
        XCTAssertFalse(warning.contains("Jordan"), "the warning counts; it never quotes a value")
        XCTAssertEqual(model.aiCoverage.workspaceRecord, .ranPartially)
        XCTAssertTrue(
            AIScanCoverage.restored(from: .ranPartially).unlocatedValues.isEmpty,
            "a reopened workspace is still warned as partial but carries no values"
        )
    }

    // MARK: - Where a listed value is written

    func testACaseVariantKeepsTheValueExposed() {
        let text = "JORDAN LEE2 signed; Jordan Lee3 witnessed."
        let ns = text as NSString
        let upper = ns.range(of: "JORDAN LEE")
        let lower = ns.range(of: "Jordan Lee")
        let placement = UnlocatedValuePlacement.of(ExtractedEntity(value: "Jordan Lee", type: .person), in: text)
        XCTAssertEqual(placement.runIns, [upper, lower])

        XCTAssertEqual(
            UnlocatedValueProtection.of(placement, entities: [Self.entity(lower, in: text)]),
            .exposed(remaining: 1),
            "an uncovered case variant is still in clear"
        )
        XCTAssertEqual(
            UnlocatedValueProtection.of(
                placement,
                entities: [Self.entity(upper, in: text), Self.entity(lower, in: text)]
            ),
            .protected
        )
    }

    func testAnEntityKeptVisibleDoesNotProtect() {
        let text = "Signed by Jordan Lee2."
        let range = (text as NSString).range(of: "Jordan Lee")
        let placement = UnlocatedValuePlacement.of(ExtractedEntity(value: "Jordan Lee", type: .person), in: text)
        XCTAssertEqual(
            UnlocatedValueProtection.of(placement, entities: [Self.entity(range, in: text, accepted: false)]),
            .exposed(remaining: 1)
        )
    }

    func testAValueOnlyInsideOtherWordsOffersNothingToProtect() {
        let placement = UnlocatedValuePlacement.of(
            ExtractedEntity(value: "Lee", type: .person),
            in: "The Leeds office signed."
        )
        XCTAssertTrue(placement.runIns.isEmpty)
        XCTAssertEqual(UnlocatedValueProtection.of(placement, entities: []), .insideOtherWords)
    }

    func testAValueTheDocumentWritesDifferentlyIsWrittenDifferently() {
        let placement = UnlocatedValuePlacement.of(
            ExtractedEntity(value: "JohnSmith", type: .person),
            in: "Signed by John Smith."
        )
        XCTAssertEqual(UnlocatedValueProtection.of(placement, entities: []), .writtenDifferently)
    }

    // MARK: - Headers, footers and notes of a .docx

    func testAProtectedValueIsRedactedWhereItIsRunInOutsideTheBody() {
        // Review finding: Review said Protected while a footer that wrote the
        // value the same way exported it in clear, because the non-body pass
        // never sees the body's manual entities and refuses the same edge.
        let footer = "Prepared for Jordan Lee2 | The Jordan Leeds office | Confidential"
        let protected = [ExtractedEntity(value: "Jordan Lee", type: .person)]

        let spans = ReviewModel.nonBodyDetector(
            useLLM: false, modelPath: nil, custom: [], protectedRunIns: protected
        )(footer)

        let runIn = (footer as NSString).range(of: "Jordan Lee2")
        XCTAssertTrue(
            spans.contains { $0.start == runIn.location && $0.end == runIn.location + 10 && $0.type == .person },
            "the run-in mention in the footer is redacted"
        )
        let leeds = (footer as NSString).range(of: "Jordan Leeds")
        XCTAssertFalse(
            spans.contains { $0.start < NSMaxRange(leeds) && $0.end > leeds.location },
            "an ordinary word is never cut"
        )

        let unprotected = ReviewModel.nonBodyDetector(useLLM: false, modelPath: nil, custom: [])(footer)
        XCTAssertFalse(
            unprotected.contains { $0.type == .person },
            "nothing changes for a value the user did not protect"
        )
    }

    // MARK: - Copy

    func testTheShowValuesControlCountsInEveryShippedLanguage() throws {
        XCTAssertEqual(AIScanCoveragePresentation.showValuesTitle(count: 2, language: .english), "Show 2 values")
        XCTAssertEqual(AIScanCoveragePresentation.showValuesTitle(count: 2, language: .french), "Afficher 2 valeurs")
        XCTAssertEqual(AIScanCoveragePresentation.showValuesTitle(count: 1, language: .french), "Afficher 1 valeur")
        XCTAssertEqual(AIScanCoveragePresentation.showValuesTitle(count: 2, language: .simplifiedChinese), "显示 2 个值")
        XCTAssertEqual(AIScanCoveragePresentation.showValuesTitle(count: 2, language: .traditionalChinese), "顯示 2 個值")

        // Keys chosen by a ternary are invisible to LocalizationRoutingTests'
        // literal scan, so they are checked here.
        for identifier in Self.catalogIdentifiers {
            let catalog = try Self.catalog(identifier)
            for key in [
                "Show %lld value",
                "Show %lld values",
                "AI found %lld value it could not locate exactly in some places, so it was not redacted there. It stays in the document until you protect it.",
                "AI found %lld values it could not locate exactly in some places, so they were not redacted there. They stay in the document until you protect them."
            ] {
                let translation = try XCTUnwrap(catalog[key], "\(identifier) has no entry for \(key)")
                XCTAssertTrue(translation.contains("%lld"), "\(identifier) drops the count in \(key)")
            }
        }
    }

    // MARK: - Helpers

    private static let catalogIdentifiers = ["en", "fr", "zh-Hans", "zh-Hant"]

    private static let uiSourcesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LDAUI", isDirectory: true)

    private static func catalog(_ identifier: String) throws -> [String: String] {
        let url = uiSourcesDirectory
            .appendingPathComponent("Resources/\(identifier).lproj/Localizable.strings")
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "could not parse \(identifier)"
        )
    }

    private static func uiSource(_ name: String) throws -> String {
        try String(contentsOf: uiSourcesDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    private static func entity(_ range: NSRange, in text: String, accepted: Bool = true) -> ReviewEntity {
        ReviewEntity(
            span: Span(
                start: range.location,
                end: NSMaxRange(range),
                type: .person,
                text: (text as NSString).substring(with: range),
                source: .manual,
                confidence: 1.0,
                priority: 110
            ),
            accepted: accepted
        )
    }
}
