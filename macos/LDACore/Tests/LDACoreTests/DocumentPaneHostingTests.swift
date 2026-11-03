//
//  DocumentPaneHostingTests.swift
//  LDACoreTests
//
//  The document pane hosted for real (NSHostingView in an offscreen window):
//  the selectable text view appears with the document text, a selection
//  reaches the model and opens the gate, the context menu leads with the
//  guessed kind for the quoted value, protecting from it adds every
//  occurrence and restyles the text with the hue underline while the
//  selection survives, and Safe Preview turns selection off and offers only
//  the way back. This is the end-to-end wiring the unit tests cannot see.
//
//  House rules: English only. Fixture strings may be Chinese. No em-dash or
//  en-dash-as-separator.
//

import AppKit
import SwiftUI
import XCTest
@testable import LDAUI
@testable import LDACore

@MainActor
final class DocumentPaneHostingTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentPaneHostingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    /// Let SwiftUI flush its pending view updates into the AppKit hierarchy.
    private func settle(_ host: NSView) {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// A point (window coordinates) in the middle of a character range.
    private static func windowPoint(inside range: NSRange, of textView: NSTextView) throws -> NSPoint {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        layoutManager.ensureLayout(for: container)
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        return textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    func testPopulatedReviewKeepsBothColumnsInsideTheWindowAfterResize() async throws {
        let source = workDir.appendingPathComponent("Resize sample.txt")
        let text = "张明 works at Example LLC. Email demo@example.test on 2026-11-03."
        try text.write(to: source, atomically: true, encoding: .utf8)
        let session = SessionModel(makeModel: { ReviewModel(modelPath: nil) },
                                   clientStore: { try ClientMappingStore(rootDirectory: self.workDir.appendingPathComponent("clients")) })
        await session.addDocuments([source])
        let model = session.activeModel
        let suiteName = TestNamespace.suiteName("ReviewResizeTests")
        let preferences = UserDefaults(suiteName: suiteName)!
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: "com.haotianyi.LDA.hasCompletedFirstRun")
        let importer = ModelImporter(catalog: ModelCatalog(tiers: []),
                                     fileManager: ModelContainerStub(supportRoot: workDir))
        let modes = AppModeStore()
        let shell = RootShell(session: session, fillModel: FillModel(modelPath: nil), modeStore: modes,
                              installer: ModelInstaller(), importer: importer)
            .defaultAppStorage(preferences)
            .environment(\.appLanguage, .simplifiedChinese)
        let host = NSHostingView(rootView: GeometryReader { geometry in
            shell.frame(width: geometry.size.width, height: geometry.size.height)
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1307, height: 904),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        let ns = text as NSString
        model.entities = [("张明", EntityType.person), ("Example LLC", .company),
                          ("demo@example.test", .email), ("2026-11-03", .date)].map { value, type in
            let range = ns.range(of: value)
            return ReviewEntity(span: Span(start: range.location, end: NSMaxRange(range), type: type,
                                           text: value, source: .manual, confidence: 1, priority: 30), accepted: true)
        }
        model.status = .ready
        model.previewMode = .safePreview
        for size in [NSSize(width: 2560, height: 1300), NSSize(width: 1307, height: 904), NSSize(width: 1100, height: 720)] {
            window.setContentSize(size)
            settle(host)
            let split = try XCTUnwrap(Self.find(NSSplitView.self, in: host))
            let bounds = split.convert(split.bounds, to: host)
            XCTAssertGreaterThanOrEqual(bounds.minX, -1, "The sidebar must not slide beyond the window edge.")
            XCTAssertLessThanOrEqual(bounds.maxX, size.width + 1, "Review content must not expand its native split view.")
            let textView = try XCTUnwrap(Self.find(ProtectableTextView.self, in: host))
            let scroll = try XCTUnwrap(textView.enclosingScrollView)
            let scrollBounds = scroll.convert(scroll.bounds, to: host)
            XCTAssertGreaterThanOrEqual(scrollBounds.minX, 0)
            XCTAssertLessThanOrEqual(scrollBounds.maxX, size.width + 1)
        }
        func splitViews(in view: NSView) -> [NSSplitView] {
            (view as? NSSplitView).map { [$0] } ?? []
                + view.subviews.flatMap { splitViews(in: $0) }
        }
        XCTAssertEqual(splitViews(in: host).count, 1, "Only the active mode may attach a native split view.")
        modes.activeMode = .deanonymize
        settle(host)
        XCTAssertEqual(splitViews(in: host).count, 0)
        modes.activeMode = .anonymize
        settle(host)
        XCTAssertEqual(splitViews(in: host).count, 1)
        XCTAssertEqual(model.entities.count, 4)
        XCTAssertEqual(model.previewMode, .safePreview)
        XCTAssertTrue(try XCTUnwrap(Self.find(ProtectableTextView.self, in: host)).string.contains("{PERSON_1}"))
        window.contentView = nil
    }

    func testHostedPaneRendersSelectableTextAndProtectsFromTheContextMenu() throws {
        let text = "甲方：张三。联系人 张三，邮箱 zhang.san@example.com。张三签署。"
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        model.documentText = text
        model.status = .imported
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: { model },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DocumentPane(session: session, model: model))
        window.contentView = host
        settle(host)

        let textView = try XCTUnwrap(
            Self.find(ProtectableTextView.self, in: host),
            "the pane hosts the selectable text view"
        )
        XCTAssertEqual(textView.string, text)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertFalse(textView.isEditable)
        XCTAssertNotNil(textView.enclosingScrollView, "the text view owns its scroll view")

        // A selection reaches the model and opens the gate.
        let range = (text as NSString).range(of: "张三")
        textView.setSelectedRange(range)
        XCTAssertEqual(model.selectedTextRange, range)
        XCTAssertTrue(model.canProtectSelection)
        XCTAssertEqual(model.selectedText, "张三")

        // The context menu leads with the guessed kind for the quoted value,
        // followed by the standard text items. The right-click lands INSIDE
        // the selection: AppKit moves the selection to the pointer when the
        // click is outside it, which is the real behavior too.
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: try Self.windowPoint(inside: range, of: textView),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let menu = try XCTUnwrap(textView.menu(for: event))
        let first = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(
            first.title,
            String(
                format: L10n.string("Protect “%@” as %@"),
                "张三" as NSString,
                EntityTypePresentation.localizedName(for: .person) as NSString
            )
        )
        XCTAssertNotNil(menu.items[1].submenu)
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertGreaterThan(menu.items.count, 3, "the standard text menu follows")

        DocumentTextContextMenu.perform(first)
        XCTAssertEqual(model.entities.count, 3)
        XCTAssertTrue(model.entities.allSatisfy { $0.span.type == .person && $0.span.source == .manual && $0.accepted })
        XCTAssertNotNil(model.protectNotice)
        XCTAssertEqual(model.selectedGroupIDs, [ReviewModel.groupID(value: "张三", type: .person)])

        // The pane restyles: the protected range carries the hue underline and
        // the selection survives so a follow-up right-click still works.
        settle(host)
        let storage = try XCTUnwrap(textView.textStorage)
        let attributes = storage.attributes(at: range.location, effectiveRange: nil)
        XCTAssertEqual(attributes[.underlineStyle] as? Int, DocumentHighlightStyle.acceptedUnderline.rawValue)
        XCTAssertNotNil(attributes[.toolTip])
        XCTAssertEqual(textView.selectedRange(), range)

        // Safe Preview shows the tokens and stays selectable, but the two
        // surfaces have different offsets, so the Original-mode selection is
        // dropped on the way in rather than reinterpreted.
        model.previewMode = .safePreview
        settle(host)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertNil(model.selectedTextRange)
        XCTAssertFalse(model.canProtectSelection)
        XCTAssertTrue(textView.string.contains("{PERSON_1}"), textView.string)
        XCTAssertFalse(textView.string.contains("张三"))

        // The pane installs the rendering it is showing together with its
        // pairing, which is what the selection gate reads.
        XCTAssertEqual(model.safePreviewSurface.text, textView.string)
        XCTAssertNotNil(
            model.safePreviewSurface.pairing,
            "the rendering on screen must be paired back to the original"
        )

        // Selecting a stand-in is refused, and the menu says why instead of
        // offering to protect the token.
        let preview = textView.string as NSString
        let tokenRange = preview.range(of: "{PERSON_1}")
        textView.setSelectedRange(tokenRange)
        XCTAssertEqual(model.protectableSelection(for: model.selectedTextRange), .standIn("{PERSON_1}"))

        // Right-clicking inside the token: AppKit re-selects under the
        // pointer while the menu is built, so the assertions below read the
        // selection the menu actually described.
        let tokenEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: try Self.windowPoint(inside: tokenRange, of: textView),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let safeMenu = try XCTUnwrap(textView.menu(for: tokenEvent))
        let underPointer = textView.selectedRange()
        guard case .standIn(let shown) = model.protectableSelection(for: underPointer) else {
            return XCTFail(
                "the right-click landed outside the stand-in: "
                    + preview.substring(with: underPointer)
            )
        }
        let refusal = try XCTUnwrap(safeMenu.items.first)
        XCTAssertFalse(refusal.isEnabled, "a stand-in offers nothing to protect")
        XCTAssertTrue(refusal.title.contains(shown), refusal.title)
        XCTAssertEqual(
            refusal.title,
            ProtectSelectionPresentation.refusal(for: .standIn(shown)),
            "the item states the same refusal the notice row would"
        )
        XCTAssertEqual(safeMenu.items[1].title, L10n.string("Show Original to Select Text"))

        // Text the rendering carried through is the document's own text, so
        // it can be protected from here.
        textView.setSelectedRange(preview.range(of: "zhang.san@example.com"))
        XCTAssertEqual(
            model.protectableSelection(for: model.selectedTextRange),
            .value("zhang.san@example.com")
        )
        XCTAssertTrue(model.canProtectSelection)
        XCTAssertEqual(model.selectedText, "zhang.san@example.com")
        model.selectedTextRange = nil

        model.previewMode = .original
        settle(host)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertEqual(textView.string, text)
    }
}
