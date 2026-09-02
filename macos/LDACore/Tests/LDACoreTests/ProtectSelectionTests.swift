//
//  ProtectSelectionTests.swift
//  LDACoreTests
//
//  ReviewModel.protectSelection: the behavior behind "select text, then
//  Protect as <kind>". Pinned here: the trimming set (periods kept), the
//  single-paragraph rule, the retype and re-accept paths, the overlap policy
//  (the user's hand wins over partial overlaps; a selection strictly inside a
//  protected span is a no-op with an explanation; strictly inside a
//  kept-visible span it replaces), the role-label block and its override, the
//  gate every entry point reads, and undo/redo through UndoManager without
//  ever recording a learned suppression.
//
//  House rules: English only. Fixture strings may be Chinese. No em-dash or
//  en-dash-as-separator.
//

import XCTest
@testable import LDAUI
@testable import LDACore

@MainActor
final class ProtectSelectionTests: XCTestCase {

    private static let text = "Party 张三 signed. Contact 张三 at jane@x.example. 张三 again. 甲方 confirms.\n"
        + "Second paragraph mentions Acme Holdings Ltd and Acme."

    private static let ns = text as NSString

    /// The UTF-16 range of the n-th occurrence of `surface` in the fixture.
    private static func range(of surface: String, occurrence: Int = 0) -> NSRange {
        var searchStart = 0
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = ns.range(
                of: surface,
                range: NSRange(location: searchStart, length: ns.length - searchStart)
            )
            precondition(found.location != NSNotFound, "fixture surface missing: \(surface)")
            searchStart = found.location + found.length
        }
        return found
    }

    private static func entity(
        _ surface: String,
        _ type: EntityType,
        occurrence: Int = 0,
        accepted: Bool = true,
        source: DetectionSource = .llm
    ) -> ReviewEntity {
        let range = range(of: surface, occurrence: occurrence)
        return ReviewEntity(
            span: Span(
                start: range.location, end: range.location + range.length,
                type: type, text: surface, source: source, confidence: 0.9, priority: 30
            ),
            accepted: accepted
        )
    }

    private func makeModel(entities: [ReviewEntity] = [], status: ReviewStatus = .ready) -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        model.documentText = Self.text
        model.entities = entities
        model.status = status
        return model
    }

    // MARK: - Trimming

    func testTrimmingStripsWhitespaceAndTheFixedPunctuationSetButKeepsPeriods() {
        XCTAssertEqual(ProtectSelectionRules.trim(" “张三”， "), "张三")
        XCTAssertEqual(ProtectSelectionRules.trim("(Acme Inc.)"), "Acme Inc.")
        XCTAssertEqual(ProtectSelectionRules.trim("Acme Inc."), "Acme Inc.")
        XCTAssertEqual(ProtectSelectionRules.trim("《合同》。"), "合同")
        XCTAssertEqual(ProtectSelectionRules.trim("\n 张三 \n"), "张三")
        XCTAssertEqual(ProtectSelectionRules.trim("【甲方】：'John'"), "甲方】：'John")
        XCTAssertEqual(ProtectSelectionRules.trim("，。；"), "")
    }

    // MARK: - Protecting

    func testProtectSelectionAddsEveryOccurrenceAsAcceptedManualAndRevealsTheGroup() {
        let model = makeModel()

        let outcome = model.protectSelection(
            range: Self.range(of: "张三"), type: .person, undoManager: nil
        )

        XCTAssertEqual(outcome.value, "张三")
        XCTAssertEqual(outcome.added, 3)
        XCTAssertEqual(outcome.replaced, 0)
        XCTAssertNil(outcome.refusal)
        XCTAssertEqual(model.entities.count, 3)
        for entity in model.entities {
            XCTAssertEqual(entity.span.type, .person)
            XCTAssertEqual(entity.span.source, .manual)
            XCTAssertEqual(entity.span.priority, 110)
            XCTAssertTrue(entity.accepted)
            XCTAssertEqual(Self.ns.substring(with: NSRange(location: entity.span.start, length: entity.span.end - entity.span.start)), "张三")
        }
        let group = model.entityGroups[0]
        XCTAssertEqual(model.selectedGroupIDs, [group.id])
        XCTAssertEqual(model.groupToReveal, group.id)

        let notice = model.protectNotice
        XCTAssertNotNil(notice)
        XCTAssertTrue(notice?.canUndo == true)
        XCTAssertTrue(notice?.canChangeKind == true)
        XCTAssertFalse(notice?.offersProtectAnyway == true)
        XCTAssertTrue(notice?.message.contains("张三") == true)
        XCTAssertTrue(notice?.message.contains("3") == true)
    }

    func testTheSelectionIsTrimmedBeforeMatching() {
        let model = makeModel()
        // The drag caught the space before and the space plus period after.
        let sloppy = NSRange(location: Self.range(of: "张三").location - 1, length: 4)

        let outcome = model.protectSelection(range: sloppy, type: .person, undoManager: nil)

        XCTAssertEqual(outcome.value, "张三")
        XCTAssertEqual(outcome.added, 3)
    }

    func testASelectionAcrossParagraphsIsRefused() {
        let model = makeModel(entities: [Self.entity("张三", .person)])
        let confirms = Self.range(of: "confirms.")
        let across = NSRange(location: confirms.location, length: Self.ns.length - confirms.location)

        let outcome = model.protectSelection(range: across, type: .person, undoManager: nil)

        XCTAssertEqual(outcome.refusal, .multipleParagraphs)
        XCTAssertEqual(model.entities.count, 1)
        XCTAssertEqual(model.protectNotice?.message, ProtectSelectionPresentation.message(for: outcome))
        XCTAssertFalse(model.protectNotice?.canUndo == true)
    }

    func testAnEmptyOrOutOfRangeSelectionIsRefusedWithoutANotice() {
        let model = makeModel()
        XCTAssertEqual(
            model.protectSelection(range: NSRange(location: 0, length: 0), type: .person, undoManager: nil).refusal,
            .emptySelection
        )
        XCTAssertEqual(
            model.protectSelection(range: NSRange(location: Self.ns.length - 1, length: 5), type: .person, undoManager: nil).refusal,
            .emptySelection
        )
        // The single space after "Party" trims to nothing.
        let spaceAfterParty = NSRange(location: Self.range(of: "Party").length, length: 1)
        XCTAssertEqual(Self.ns.substring(with: spaceAfterParty), " ")
        XCTAssertEqual(
            model.protectSelection(range: spaceAfterParty, type: .person, undoManager: nil).refusal,
            .emptySelection
        )
        XCTAssertNil(model.protectNotice)
        XCTAssertTrue(model.entities.isEmpty)
    }

    // MARK: - Retype and re-accept

    func testRetypeChangesEveryOccurrenceOfTheValueWithoutAddingSpans() {
        let model = makeModel(entities: [
            Self.entity("张三", .company, occurrence: 0),
            Self.entity("张三", .company, occurrence: 1),
            Self.entity("张三", .company, occurrence: 2)
        ])
        let before = model.entities.map(\.id)

        let outcome = model.protectSelection(range: Self.range(of: "张三", occurrence: 1), type: .person, undoManager: nil)

        XCTAssertEqual(outcome.retyped, 3)
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.previousType, .company)
        XCTAssertEqual(model.entities.map(\.id), before, "retype keeps the entity identities")
        XCTAssertTrue(model.entities.allSatisfy { $0.span.type == .person && $0.span.source == .manual && $0.accepted })
        XCTAssertTrue(model.protectNotice?.message.contains(EntityTypePresentation.localizedName(for: .company)) == true, "the notice names the previous kind")
    }

    func testRetypeAlsoProtectsUncoveredOccurrencesOfTheSameValue() {
        // The model caught two of three; asking to protect the value protects
        // the third as well, since more redaction is the safe direction.
        let model = makeModel(entities: [
            Self.entity("张三", .company, occurrence: 0),
            Self.entity("张三", .company, occurrence: 2)
        ])

        let outcome = model.protectSelection(range: Self.range(of: "张三"), type: .person, undoManager: nil)

        XCTAssertEqual(outcome.retyped, 2)
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(model.entities.count, 3)
        XCTAssertEqual(model.groups(of: .person).first?.occurrences, 3)
    }

    func testReAcceptTurnsAKeptVisibleValueBackOn() {
        let model = makeModel(entities: [
            Self.entity("张三", .person, occurrence: 0, accepted: false),
            Self.entity("张三", .person, occurrence: 1, accepted: false),
            Self.entity("张三", .person, occurrence: 2, accepted: false)
        ])

        let outcome = model.protectSelection(range: Self.range(of: "张三"), type: .person, undoManager: nil)

        XCTAssertEqual(outcome.retyped, 3)
        XCTAssertEqual(outcome.previousType, .person)
        XCTAssertTrue(model.entities.allSatisfy(\.accepted))
    }

    func testProtectVariantReflectsWhatAlreadyExistsForTheValue() {
        XCTAssertEqual(makeModel().protectVariant(for: "张三"), .protect(occurrences: 3))
        XCTAssertEqual(
            makeModel(entities: [Self.entity("张三", .company)]).protectVariant(for: "张三"),
            .changeKind(current: .company)
        )
        XCTAssertEqual(
            makeModel(entities: [Self.entity("张三", .person, accepted: false)]).protectVariant(for: "张三"),
            .protectAgain(current: .person)
        )
        XCTAssertEqual(makeModel().protectVariant(for: "nowhere"), .protect(occurrences: 0))
    }

    // MARK: - Overlap policy

    func testAPartialOverlapReplacesTheEarlierFindingAndReportsIt() {
        let model = makeModel(entities: [
            Self.entity("Acme", .company, occurrence: 0),
            Self.entity("Acme", .company, occurrence: 1)
        ])
        let secondAcme = model.entities[1]

        let outcome = model.protectSelection(range: Self.range(of: "Acme Holdings Ltd"), type: .company, undoManager: nil)

        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.replaced, 1)
        XCTAssertEqual(model.entities.count, 2)
        XCTAssertTrue(model.entities.contains(secondAcme), "the non-overlapping finding survives")
        XCTAssertTrue(model.entities.contains { $0.span.text == "Acme Holdings Ltd" && $0.span.source == .manual })
        XCTAssertTrue(model.protectNotice?.message.contains("1") == true)
    }

    func testASelectionStrictlyInsideAProtectedSpanIsANoOpWithAnExplanation() {
        let model = makeModel(entities: [
            Self.entity("张三", .person, occurrence: 0),
            Self.entity("张三", .person, occurrence: 1),
            Self.entity("张三", .person, occurrence: 2)
        ])
        let before = model.entities
        let inside = NSRange(location: Self.range(of: "张三").location + 1, length: 1)

        let outcome = model.protectSelection(range: inside, type: .person, undoManager: nil)

        XCTAssertEqual(outcome.refusal, .insideProtected(container: "张三"))
        XCTAssertEqual(outcome.skippedInsideProtected, 3)
        XCTAssertEqual(model.entities, before)
        XCTAssertTrue(model.protectNotice?.message.contains("张三") == true)
        XCTAssertTrue(model.protectNotice?.message.contains("三") == true)
        XCTAssertFalse(model.protectNotice?.canUndo == true)
    }

    func testASelectionStrictlyInsideAKeptVisibleSpanReplacesIt() {
        let model = makeModel(entities: [
            Self.entity("张三", .person, occurrence: 0, accepted: false)
        ])
        let inside = NSRange(location: Self.range(of: "张三").location + 1, length: 1)

        let outcome = model.protectSelection(range: inside, type: .person, undoManager: nil)

        XCTAssertEqual(outcome.replaced, 1, "the kept-visible span is removed")
        XCTAssertEqual(outcome.added, 3, "every literal occurrence of the selection is protected")
        XCTAssertFalse(model.entities.contains { $0.span.text == "张三" })
        XCTAssertEqual(model.entities.filter { $0.span.text == "三" }.count, 3)
    }

    // MARK: - Role labels

    func testARoleLabelIsBlockedUntilProtectedAnyway() {
        let model = makeModel()
        let range = Self.range(of: "甲方")

        let blocked = model.protectSelection(range: range, type: .company, undoManager: nil)
        XCTAssertEqual(blocked.refusal, .roleLabel)
        XCTAssertTrue(model.entities.isEmpty)
        XCTAssertTrue(model.protectNotice?.offersProtectAnyway == true)
        XCTAssertEqual(model.protectNotice?.range, range)

        let forced = model.protectSelection(range: range, type: .company, undoManager: nil, allowRoleLabel: true)
        XCTAssertNil(forced.refusal)
        XCTAssertEqual(forced.added, 1)
        XCTAssertEqual(model.entities.first?.span.text, "甲方")
    }

    // MARK: - Undo

    func testUndoRestoresTheExactPriorEntityListAndRedoReapplies() throws {
        let model = makeModel(entities: [
            Self.entity("Acme", .company, occurrence: 0),
            Self.entity("Acme", .company, occurrence: 1)
        ])
        let before = model.entities
        let undoManager = UndoManager()

        model.protectSelection(range: Self.range(of: "Acme Holdings Ltd"), type: .company, undoManager: undoManager)
        let after = model.entities
        XCTAssertNotEqual(after, before)
        XCTAssertTrue(undoManager.canUndo)
        XCTAssertEqual(
            undoManager.undoActionName,
            String(
                format: L10n.string("Protect as %@"),
                EntityTypePresentation.localizedName(for: .company) as NSString
            )
        )

        undoManager.undo()
        XCTAssertEqual(model.entities, before, "undo restores the exact prior list, identities included")
        XCTAssertNil(model.protectNotice, "the notice is gone once its action is undone")

        XCTAssertTrue(undoManager.canRedo)
        undoManager.redo()
        XCTAssertEqual(model.entities, after)
    }

    func testUndoNeverRecordsALearnedSuppression() {
        let (defaults, name) = TestNamespace.defaults("protect-undo")
        defer { defaults.removePersistentDomain(forName: name) }
        let learning = ScopedLearningStore(
            global: LearningStore(defaults: defaults, storageKey: "ldatest-protect-\(UUID().uuidString)")
        )
        let model = makeModel()
        model.learningStore = learning
        let undoManager = UndoManager()

        model.protectSelection(range: Self.range(of: "张三"), type: .person, undoManager: undoManager)
        undoManager.undo()

        XCTAssertTrue(model.entities.isEmpty)
        XCTAssertTrue(learning.suppressKeys.isEmpty, "a removed span is not a rejection")
        XCTAssertTrue(learning.redactPatterns.isEmpty)
    }

    func testTypedPathKeepsSkipOverlapSemanticsAndGainsUndo() {
        let model = makeModel(entities: [Self.entity("Acme", .company, occurrence: 0)])
        let before = model.entities
        let undoManager = UndoManager()

        let added = model.addManualEntity(text: "Acme Holdings Ltd", type: .company, undoManager: undoManager)

        XCTAssertEqual(added, 0, "typing a value you cannot see never deletes detections")
        XCTAssertEqual(model.entities, before)
        XCTAssertFalse(undoManager.canUndo, "nothing changed, nothing to undo")

        XCTAssertEqual(model.addManualEntity(text: "张三", type: .person, undoManager: undoManager), 3)
        XCTAssertTrue(undoManager.canUndo)
        undoManager.undo()
        XCTAssertEqual(model.entities, before)
    }

    // MARK: - Gate and requests

    func testCanProtectSelectionReadsSelectionModeAndStatus() {
        let model = makeModel(status: .imported)
        XCTAssertFalse(model.canProtectSelection, "no selection yet")

        model.selectedTextRange = Self.range(of: "张三")
        XCTAssertTrue(model.canProtectSelection)
        XCTAssertEqual(model.selectedText, "张三")

        model.previewMode = .safePreview
        XCTAssertFalse(model.canProtectSelection, "Safe Preview has no selectable text")
        model.previewMode = .original

        model.status = .detecting
        XCTAssertFalse(model.canProtectSelection, "the entity list is being rebuilt")
        model.status = .ready
        XCTAssertTrue(model.canProtectSelection)

        model.selectedTextRange = NSRange(location: 0, length: 0)
        XCTAssertFalse(model.canProtectSelection)
        XCTAssertNil(model.selectedText)
    }

    func testRequestProtectSelectionBumpsTheTokenOnlyWhenAllowed() {
        let model = makeModel()
        model.requestProtectSelection()
        XCTAssertEqual(model.protectSelectionRequestToken, 0)

        model.selectedTextRange = Self.range(of: "张三")
        model.requestProtectSelection()
        XCTAssertEqual(model.protectSelectionRequestToken, 1)
    }

    func testOpeningAnotherDocumentClearsTheSelectionAndTheNotice() async throws {
        let model = makeModel()
        model.selectedTextRange = Self.range(of: "张三")
        model.protectSelection(range: Self.range(of: "张三"), type: .person, undoManager: nil)
        XCTAssertNotNil(model.protectNotice)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectSelectionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("next.txt")
        try Data("Fresh text.".utf8).write(to: url)

        await model.open(url)

        XCTAssertNil(model.selectedTextRange)
        XCTAssertNil(model.protectNotice)
        XCTAssertEqual(model.previewMode, .original)
    }

    // MARK: - Presentation

    func testNoticeMessagesQuoteTheTrimmedValueAndTheKind() {
        let person = EntityTypePresentation.localizedName(for: .person)
        let protected = ProtectSelectionPresentation.message(for: ProtectOutcome(
            value: "张三", type: .person, previousType: nil,
            added: 3, replaced: 0, retyped: 0, skippedInsideProtected: 0, refusal: nil
        ))
        XCTAssertTrue(protected.contains("“张三”"), protected)
        XCTAssertTrue(protected.contains(person), protected)
        XCTAssertTrue(protected.contains("3"), protected)

        let replaced = ProtectSelectionPresentation.message(for: ProtectOutcome(
            value: "Acme Holdings Ltd", type: .company, previousType: nil,
            added: 1, replaced: 2, retyped: 0, skippedInsideProtected: 0, refusal: nil
        ))
        XCTAssertTrue(replaced.contains("2"), replaced)

        let inside = ProtectSelectionPresentation.message(for: ProtectOutcome(
            value: "三", type: .person, previousType: nil,
            added: 0, replaced: 0, retyped: 0, skippedInsideProtected: 1,
            refusal: .insideProtected(container: "张三")
        ))
        XCTAssertTrue(inside.contains("“三”") && inside.contains("“张三”"), inside)

        let announcement = ProtectSelectionPresentation.announcement(for: ProtectOutcome(
            value: "张三", type: .person, previousType: nil,
            added: 3, replaced: 0, retyped: 0, skippedInsideProtected: 0, refusal: nil
        ))
        XCTAssertTrue(announcement.contains("张三") && announcement.contains(person), announcement)
    }
}
