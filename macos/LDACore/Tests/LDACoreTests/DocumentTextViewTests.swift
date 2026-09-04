//
//  DocumentTextViewTests.swift
//  LDACoreTests
//
//  The AppKit layer under the document pane: the non-editable, selectable
//  text view that reports its selection (UTF-16, Span semantics), keeps the
//  reading column geometry, never competes with the highlight underlines
//  (spelling and grammar marks off), and prepends the Protect items to the
//  standard text context menu. The menu builder is pure so its titles, order,
//  enabled state, and actions are pinned without a window.
//
//  House rules: English only. Fixture strings may be Chinese. No em-dash or
//  en-dash-as-separator.
//

import AppKit
import XCTest
@testable import LDAUI
import LDACore

@MainActor
final class DocumentTextViewTests: XCTestCase {

    private func context(
        isOriginalVisible: Bool = true,
        canProtect: Bool = true,
        guess: EntityType = .person,
        resolve: @escaping (NSRange?) -> ProtectableSelection = { _ in .nothing },
        onProtect: @escaping (EntityType) -> Void = { _ in },
        onShowOriginal: @escaping () -> Void = {}
    ) -> DocumentTextMenuContext {
        DocumentTextMenuContext(
            isOriginalVisible: isOriginalVisible,
            canProtect: canProtect,
            assignableTypes: AssignableEntityTypes.manual,
            guess: { _ in guess },
            resolve: resolve,
            onProtect: onProtect,
            onShowOriginal: onShowOriginal
        )
    }

    private func protectTitle(_ value: String, _ type: EntityType) -> String {
        String(
            format: L10n.string("Protect “%@” as %@"),
            value as NSString,
            EntityTypePresentation.localizedName(for: type) as NSString
        )
    }

    // MARK: - Context menu builder

    func testOriginalModeMenuLeadsWithTheGuessedKindThenTheSubmenuThenASeparator() {
        var protected: [EntityType] = []
        let items = DocumentTextContextMenu.protectItems(
            .value("张三"),
            context: context(guess: .person, onProtect: { protected.append($0) })
        )

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].title, protectTitle("张三", .person))
        XCTAssertTrue(items[0].isEnabled)
        XCTAssertEqual(items[1].title, String(format: L10n.string("Protect “%@” as…"), "张三" as NSString))
        XCTAssertTrue(items[2].isSeparatorItem)

        let submenu = items[1].submenu
        XCTAssertEqual(submenu?.items.count, AssignableEntityTypes.manual.count)
        XCTAssertEqual(
            submenu?.items.map(\.title),
            AssignableEntityTypes.manual.map {
                String(
                    format: L10n.string("Protect as %@"),
                    EntityTypePresentation.localizedName(for: $0) as NSString
                )
            },
            "submenu order mirrors the sidebar"
        )

        DocumentTextContextMenu.perform(items[0])
        let companyIndex = AssignableEntityTypes.manual.firstIndex(of: .company)!
        DocumentTextContextMenu.perform(submenu!.items[companyIndex])
        XCTAssertEqual(protected, [.person, .company])
    }

    func testMenuTitlesQuoteTheMiddleTruncatedValue() {
        // The trimming itself belongs to the model's resolver, which is what
        // hands this builder a value (ProtectSelectionTests pins the set).
        let long = String(repeating: "北京字节跳动科技有限公司", count: 3)
        let longItems = DocumentTextContextMenu.protectItems(.value(long), context: context(guess: .company))
        let shown = ProtectSelectionPresentation.menuValue(long)
        XCTAssertEqual(shown.count, 24)
        XCTAssertTrue(shown.contains("\u{2026}"))
        XCTAssertEqual(longItems[0].title, protectTitle(shown, .company))
    }

    func testMenuItemsAreGrayedWithoutAUsableSelection() {
        let items = DocumentTextContextMenu.protectItems(.nothing, context: context())
        XCTAssertEqual(items.count, 2, "one disabled item and a separator")
        XCTAssertEqual(items[0].title, L10n.string("Protect Selection…"))
        XCTAssertFalse(items[0].isEnabled)
        XCTAssertTrue(items[1].isSeparatorItem)

        let scanning = DocumentTextContextMenu.protectItems(.value("张三"), context: context(canProtect: false))
        XCTAssertFalse(scanning[0].isEnabled, "disabled while the entity list is being rebuilt")
    }

    /// The Safe Preview menu is not a dead end any more: a selection that is
    /// the document's own text can be protected from there, and one that
    /// cannot says why in the item itself rather than being merely grayed.
    func testSafePreviewMenuProtectsCarriedThroughTextAndExplainsWhatItRefuses() {
        var shown = 0
        let safePreview = context(isOriginalVisible: false, onShowOriginal: { shown += 1 })

        let protectable = DocumentTextContextMenu.protectItems(.value("张三"), context: safePreview)
        XCTAssertEqual(protectable.count, 4, "the two Protect items, the way back, a separator")
        XCTAssertEqual(protectable[0].title, protectTitle("张三", .person))
        XCTAssertTrue(protectable[0].isEnabled)
        XCTAssertEqual(protectable[2].title, L10n.string("Show Original to Select Text"))
        DocumentTextContextMenu.perform(protectable[2])
        XCTAssertEqual(shown, 1)

        let standIn = DocumentTextContextMenu.protectItems(.standIn("{PERSON_1}"), context: safePreview)
        XCTAssertEqual(standIn.count, 3)
        XCTAssertFalse(standIn[0].isEnabled)
        XCTAssertEqual(
            standIn[0].title,
            ProtectSelectionPresentation.refusal(for: .standIn("{PERSON_1}")),
            "the item states the same refusal the notice row would"
        )
        XCTAssertTrue(standIn[0].title.contains("{PERSON_1}"))
        XCTAssertEqual(standIn[1].title, L10n.string("Show Original to Select Text"))
        XCTAssertTrue(standIn[1].isEnabled)

        let undecidable = DocumentTextContextMenu.protectItems(.undecidable, context: safePreview)
        XCTAssertEqual(undecidable.count, 3)
        XCTAssertFalse(undecidable[0].isEnabled)
        XCTAssertEqual(
            undecidable[0].title,
            ProtectSelectionPresentation.refusal(for: .undecidable)
        )
        XCTAssertEqual(undecidable[1].title, L10n.string("Show Original to Select Text"))

        let empty = DocumentTextContextMenu.protectItems(.nothing, context: safePreview)
        XCTAssertEqual(empty.map(\.title).first, L10n.string("Protect Selection…"))
        XCTAssertEqual(empty.count, 3, "the way back is offered in every Safe Preview menu")
    }

    // MARK: - Text view configuration

    func testTextViewIsSelectableButNeverEditableAndShowsNoSpellingMarks() {
        let textView = ProtectableTextView.make()
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isContinuousSpellCheckingEnabled)
        XCTAssertFalse(textView.isGrammarCheckingEnabled)
        XCTAssertFalse(textView.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(textView.isAutomaticDataDetectionEnabled)
        XCTAssertFalse(textView.isAutomaticLinkDetectionEnabled)
        XCTAssertFalse(textView.usesFontPanel)
        XCTAssertFalse(textView.allowsUndo)
        XCTAssertFalse(textView.drawsBackground)
        XCTAssertEqual(textView.textContainer?.lineFragmentPadding, 0)
        XCTAssertNotNil(textView.layoutManager, "TextKit 1 so tooltips and dashed underlines render")
    }

    func testReadingColumnInsetCentersTheMeasureAndKeepsTheMinimumGutter() {
        let textView = ProtectableTextView.make()

        textView.setFrameSize(NSSize(width: 1_000, height: 200))
        XCTAssertEqual(textView.textContainerInset.width, (1_000 - DocumentTextLayout.columnWidth) / 2, accuracy: 0.5)
        XCTAssertEqual(textView.textContainerInset.height, DocumentTextLayout.columnVerticalInset)

        textView.setFrameSize(NSSize(width: 600, height: 200))
        XCTAssertEqual(textView.textContainerInset.width, DocumentTextLayout.gutter)
    }

    func testSelectionChangesAreReportedInUTF16AndProgrammaticContentUpdatesAreNot() {
        let textView = ProtectableTextView.make()
        var reported: [NSRange?] = []
        textView.onSelectionChange = { reported.append($0) }

        let text = "Party 张三 signed."
        textView.apply(content: DocumentTextStyler.styledOriginal(text: text, entities: []))
        XCTAssertEqual(textView.string, text)
        XCTAssertTrue(reported.isEmpty, "loading content is not a user selection")

        let range = (text as NSString).range(of: "张三")
        textView.setSelectedRange(range)
        XCTAssertEqual(reported.last, range)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(reported.count, 2)
        XCTAssertNil(reported.last!, "an empty selection reports nil")

        // Restyling the same text keeps the user's selection and stays silent.
        textView.setSelectedRange(range)
        reported.removeAll()
        let entity = ReviewEntity(
            span: Span(start: range.location, end: NSMaxRange(range), type: .person, text: "张三", source: .manual, confidence: 1, priority: 110),
            accepted: true
        )
        textView.apply(content: DocumentTextStyler.styledOriginal(text: text, entities: [entity]))
        XCTAssertEqual(textView.selectedRange(), range)
        XCTAssertTrue(reported.isEmpty)
    }

    func testTurningSelectionOffClearsTheSelectionSilently() {
        let textView = ProtectableTextView.make()
        var reported: [NSRange?] = []
        textView.onSelectionChange = { reported.append($0) }
        textView.apply(content: DocumentTextStyler.styledOriginal(text: "Party 张三 signed.", entities: []))
        textView.setSelectedRange(NSRange(location: 6, length: 2))
        reported.removeAll()

        textView.setSelectable(false)

        XCTAssertFalse(textView.isSelectable)
        XCTAssertEqual(textView.selectedRange().length, 0)
        XCTAssertTrue(reported.isEmpty, "the pane clears the model itself when Safe Preview shows")
    }

    // MARK: - Menu wiring

    func testAppExposesProtectSelectionInTheReviewMenuWithCommandShiftP() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/LDAApp/LDAApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(app.contains("requestProtectSelection()"))
        XCTAssertTrue(app.contains(#".keyboardShortcut("p", modifiers: [.command, .shift])"#))
        XCTAssertTrue(app.contains("canProtectSelection"))
    }
}
