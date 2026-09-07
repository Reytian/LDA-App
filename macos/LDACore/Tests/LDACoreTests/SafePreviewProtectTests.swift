//
//  SafePreviewProtectTests.swift
//  LDACoreTests
//
//  Protecting a missed value while looking at Safe Preview, and refusing to
//  when the selection cannot be attributed to the document.
//
//  The defect being guarded is not a crash. A selection in Safe Preview is
//  reported in the RENDERING's offsets; read against the original text those
//  offsets address different characters, so protecting them would key a
//  mapping on a fragment nobody chose, or worse, on a replacement. Both fail
//  at restore, quietly, which is why the tests below pin the wrong answers as
//  hard as the right one: the naive read is asserted to produce a DIFFERENT
//  value, so a future refactor that drops the pairing fails here instead of
//  in a lawyer's document.
//
//  House rules: English only. Fixture strings may be Chinese. No em-dash or
//  en-dash-as-separator.
//

import XCTest
@testable import LDAUI
@testable import LDACore

@MainActor
final class SafePreviewProtectTests: XCTestCase {

    // MARK: - Fixture

    /// A contract line with two values worth protecting and one the scan
    /// missed (the email). The two replacements are longer than what they
    /// replace, so every offset after them differs between the surfaces,
    /// which is the whole point.
    private static let original =
        "买方 北京朝阳科技有限公司 与 张三 签署本协议，邮箱 li@x.example，双方各执一份，均无异议。"

    private static func range(of surface: String, in text: String) -> NSRange {
        let found = (text as NSString).range(of: surface)
        precondition(found.location != NSNotFound, "fixture surface missing: \(surface)")
        return found
    }

    private static func entity(_ surface: String, _ type: EntityType) -> ReviewEntity {
        let found = range(of: surface, in: original)
        return ReviewEntity(
            span: Span(
                start: found.location,
                end: NSMaxRange(found),
                type: type,
                text: surface,
                source: .llm,
                confidence: 0.9,
                priority: 30
            ),
            accepted: true
        )
    }

    private static var entities: [ReviewEntity] {
        [entity("北京朝阳科技有限公司", .company), entity("张三", .person)]
    }

    /// A model showing the paired Safe Preview surface, exactly the way the
    /// pane installs it.
    private func makeModel(style: SubstitutionStyle = .token) -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        model.documentText = Self.original
        model.entities = Self.entities
        model.status = .ready
        model.setSafePreviewSurface(
            ReviewModel.redactedPreviewSurface(
                text: model.documentText,
                entities: model.entities,
                style: style
            )
        )
        model.previewMode = .safePreview
        return model
    }

    private func previewText(of model: ReviewModel) -> NSString {
        model.safePreviewSurface.text as NSString
    }

    /// A document handed to an AI in token style and then previewed in
    /// pseudonym style carries brace tokens on its entities. Those are
    /// deliberately NOT re-emitted, so the mapping holds two entries for the
    /// surface and only one of them describes the rendering on screen. The
    /// pairing has to read the one that was actually emitted, or this whole
    /// feature quietly turns off after the first handoff.
    func testASurfaceWhoseEntitiesCarryTokensFromAnEarlierHandoffStillPairs() throws {
        let carried = Self.entities.map { entity in
            ReviewEntity(
                id: entity.id,
                span: entity.span,
                accepted: true,
                token: entity.span.type == .company ? "{COMPANY_1}" : "{PERSON_1}"
            )
        }
        let surface = ReviewModel.redactedPreviewSurface(
            text: Self.original,
            entities: carried,
            style: .pseudonym
        )

        XCTAssertFalse(surface.text.contains("{COMPANY_1}"), "the brace token is not re-emitted")
        XCTAssertFalse(surface.text.contains("北京朝阳科技有限公司"))
        let pairing = try XCTUnwrap(
            surface.pairing,
            "a mapping holding a stale style entry must still pair"
        )
        let email = (surface.text as NSString).range(of: "li@x.example")
        XCTAssertEqual(
            pairing.resolve(selection: email),
            .carriedThrough(Self.range(of: "li@x.example", in: Self.original))
        )
    }

    // MARK: - The gate the pane reads

    /// The reason this whole seam exists, stated as an assertion: the same
    /// range means different text in the two surfaces.
    func testTheNaiveReadOfAPreviewRangeWouldTakeTheWrongText() {
        let model = makeModel()
        let email = previewText(of: model).range(of: "li@x.example")
        let source = Self.original as NSString

        XCTAssertLessThanOrEqual(
            NSMaxRange(email), source.length,
            "the fixture must be long enough that the wrong read is in bounds, "
                + "so this pins a wrong VALUE and not merely a refusal"
        )
        XCTAssertNotEqual(
            source.substring(with: email), "li@x.example",
            "reading a preview range against the original takes other characters; "
                + "that string is what would have become a mapping key"
        )
        XCTAssertEqual(model.protectableSelection(for: email), .value("li@x.example"))
    }

    func testASelectionInCarriedThroughTextProtectsTheValueTheUserSelected() {
        let model = makeModel()
        let email = previewText(of: model).range(of: "li@x.example")
        model.selectedTextRange = email

        XCTAssertTrue(model.canProtectSelection)
        XCTAssertEqual(model.selectedText, "li@x.example")

        let outcome = model.protectSelection(range: email, type: .email, undoManager: nil)

        XCTAssertNil(outcome.refusal)
        XCTAssertEqual(outcome.value, "li@x.example")
        XCTAssertEqual(outcome.added, 1)
        let added = model.entities.first { $0.span.type == .email }
        XCTAssertNotNil(added)
        XCTAssertEqual(added?.span.text, "li@x.example")
        XCTAssertEqual(
            added?.span.start,
            Self.range(of: "li@x.example", in: Self.original).location,
            "the new span must sit where the value is in the ORIGINAL text"
        )
        XCTAssertEqual(added?.span.source, .manual)
        XCTAssertEqual(added?.accepted, true)
    }

    func testASelectionInsideAStandInIsRefusedWithASentence() {
        let model = makeModel()
        let before = model.entities
        let token = previewText(of: model).range(of: "{COMPANY_1}")
        model.selectedTextRange = token

        // Reachable on purpose: a disabled control explains nothing.
        XCTAssertTrue(model.canProtectSelection)
        XCTAssertNil(model.selectedText, "a stand-in is never handed out as protectable text")
        XCTAssertEqual(model.protectableSelection(for: token), .standIn("{COMPANY_1}"))

        let outcome = model.protectSelection(range: token, type: .company, undoManager: nil)

        XCTAssertEqual(outcome.refusal, .standIn(shown: "{COMPANY_1}"))
        XCTAssertEqual(model.entities, before, "nothing may be minted for a replacement")
        let notice = model.protectNotice
        XCTAssertEqual(
            notice?.message,
            ProtectSelectionPresentation.message(for: outcome),
            "the refusal is spoken, not swallowed"
        )
        XCTAssertEqual(notice?.canUndo, false)
        XCTAssertEqual(notice?.offersProtectAnyway, false, "there is no override for this one")
        XCTAssertTrue(try XCTUnwrap(notice?.message).contains("{COMPANY_1}"))
    }

    func testASelectionStraddlingAStandInBoundaryIsRefused() throws {
        let model = makeModel()
        let before = model.entities
        let preview = previewText(of: model)
        let token = preview.range(of: "{PERSON_1}")
        let straddling = NSRange(location: token.location - 2, length: 4)
        XCTAssertTrue(
            preview.substring(with: straddling).contains("{"),
            "the fixture range must really cross the edge"
        )

        let outcome = model.protectSelection(range: straddling, type: .person, undoManager: nil)

        XCTAssertEqual(
            outcome.refusal,
            .standIn(shown: ProtectSelectionRules.trim(preview.substring(with: straddling)))
        )
        XCTAssertEqual(model.entities, before)
        XCTAssertNotNil(model.protectNotice)
    }

    func testAnUnpairableSurfaceRefusesInsteadOfAllowing() {
        let model = makeModel()
        let before = model.entities
        // The surface the pane could not pair: the text is on screen, the
        // pairing is not there. The answer must not be the one a paired
        // surface gives for ordinary prose.
        let text = model.safePreviewSurface.text
        model.setSafePreviewSurface(SafePreviewSurface(text: text, pairing: nil))
        let email = (text as NSString).range(of: "li@x.example")
        model.selectedTextRange = email

        XCTAssertEqual(model.protectableSelection(for: email), .undecidable)
        XCTAssertNil(model.selectedText)
        XCTAssertTrue(model.canProtectSelection, "reachable, so it can answer")

        let outcome = model.protectSelection(range: email, type: .email, undoManager: nil)

        XCTAssertEqual(outcome.refusal, .undecidableSurface)
        XCTAssertEqual(model.entities, before)
        XCTAssertEqual(
            model.protectNotice?.message,
            ProtectSelectionPresentation.message(for: outcome)
        )
    }

    /// The same shape reached the other way: an unresolved seam renders the
    /// explanatory sentence instead of the document, so it carries no
    /// pairing and nothing in it is protectable.
    func testTheSeamFailureSurfaceCarriesNoPairing() {
        let surface = SafePreviewSurface(
            text: L10n.string("Safe Preview unavailable: restoration could not be verified."),
            pairing: nil
        )
        XCTAssertNil(surface.pairing)

        let model = makeModel()
        model.setSafePreviewSurface(surface)
        XCTAssertEqual(
            model.protectableSelection(for: NSRange(location: 0, length: 4)),
            .undecidable
        )
    }

    func testRequestProtectSelectionAnswersARefusedSelectionRatherThanOpeningTheChooser() {
        let model = makeModel()
        model.selectedTextRange = previewText(of: model).range(of: "{PERSON_1}")

        model.requestProtectSelection()

        XCTAssertEqual(model.protectSelectionRequestToken, 0, "the chooser would fall back to typing")
        XCTAssertEqual(model.protectNotice?.message.isEmpty, false)

        model.protectNotice = nil
        model.selectedTextRange = previewText(of: model).range(of: "li@x.example")
        model.requestProtectSelection()
        XCTAssertEqual(model.protectSelectionRequestToken, 1)
        XCTAssertNil(model.protectNotice)
    }

    func testANewRenderingDropsASelectionMadeInTheOldOne() {
        let model = makeModel()
        model.selectedTextRange = previewText(of: model).range(of: "li@x.example")
        XCTAssertNotNil(model.selectedTextRange)

        // Restyling with the same text must not disturb the user's selection.
        model.setSafePreviewSurface(model.safePreviewSurface)
        XCTAssertNotNil(model.selectedTextRange)

        // A different rendering means those offsets address other characters.
        model.setSafePreviewSurface(
            SafePreviewSurface(text: model.safePreviewSurface.text + "。", pairing: nil)
        )
        XCTAssertNil(model.selectedTextRange)
    }

    // MARK: - The Original surface is untouched

    func testOriginalModeStillReadsItsOwnOffsetsAndIgnoresThePreviewSurface() {
        let model = makeModel()
        model.previewMode = .original
        let inOriginal = Self.range(of: "li@x.example", in: Self.original)
        model.selectedTextRange = inOriginal

        XCTAssertTrue(model.canProtectSelection)
        XCTAssertEqual(model.selectedText, "li@x.example")
        XCTAssertEqual(model.protectableSelection(for: inOriginal), .value("li@x.example"))

        let outcome = model.protectSelection(range: inOriginal, type: .email, undoManager: nil)
        XCTAssertNil(outcome.refusal)
        XCTAssertEqual(outcome.value, "li@x.example")
        XCTAssertEqual(outcome.added, 1)

        // A preview range is not an Original range, and Original mode does
        // not consult the pairing: out of bounds is simply nothing selected.
        let far = NSRange(location: (Self.original as NSString).length - 1, length: 6)
        XCTAssertEqual(model.protectableSelection(for: far), .nothing)
        XCTAssertEqual(
            model.protectSelection(range: far, type: .email, undoManager: nil).refusal,
            .emptySelection
        )
    }

    func testProtectingAStandInIsRefusedInOriginalModeTooWhenTheTextHoldsOne() {
        // A brace token typed into the document itself is ordinary text in
        // Original mode: the refusal belongs to the RENDERED surface, not to
        // the shape of the string, and this pins that the two are not
        // confused.
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        model.documentText = "模板字段 {COMPANY_1} 待填写。"
        model.status = .ready

        let range = Self.range(of: "{COMPANY_1}", in: model.documentText)
        XCTAssertEqual(model.protectableSelection(for: range), .value("{COMPANY_1}"))
    }
}
