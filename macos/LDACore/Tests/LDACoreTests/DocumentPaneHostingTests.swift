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

        // Safe Preview shows the tokens, turns selection off, clears the
        // model's selection, and offers only the way back to Original.
        model.previewMode = .safePreview
        settle(host)
        XCTAssertFalse(textView.isSelectable)
        XCTAssertNil(model.selectedTextRange)
        XCTAssertFalse(model.canProtectSelection)
        XCTAssertTrue(textView.string.contains("{PERSON_1}"), textView.string)
        XCTAssertFalse(textView.string.contains("张三"))
        let safeMenu = try XCTUnwrap(textView.menu(for: event))
        XCTAssertEqual(safeMenu.items.first?.title, L10n.string("Show Original to Select Text"))

        model.previewMode = .original
        settle(host)
        XCTAssertTrue(textView.isSelectable)
        XCTAssertEqual(textView.string, text)
    }
}
