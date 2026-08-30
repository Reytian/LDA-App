//
//  SensitiveClipboardTests.swift
//  LDACoreTests
//
//  The companion's Restore puts DE-ANONYMIZED client material on the system
//  clipboard. These tests cover the three things that make that acceptable:
//  the value is marked so clipboard managers skip archiving it, it clears
//  itself, and the clearing never destroys something the user copied in the
//  meantime.
//
//  Every test runs against a NAMED pasteboard, never NSPasteboard.general, so
//  running the suite cannot wipe the developer's own clipboard.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import AppKit
@testable import LDAUI

@MainActor
final class SensitiveClipboardTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("ai.openclaw.lda.tests.\(UUID().uuidString)"))
        pasteboard.clearContents()
    }

    override func tearDown() {
        pasteboard.clearContents()
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    // MARK: - The write itself

    func testTheValueIsActuallyOnTheClipboard() {
        SensitiveClipboard.write("Jane Aoife Smith, account 4021", pasteboard: pasteboard)

        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "Jane Aoife Smith, account 4021",
            "the restored text still has to be pasteable, that is the point"
        )
    }

    func testTheItemIsMarkedConcealedAndTransient() {
        SensitiveClipboard.write("Jane Aoife Smith", pasteboard: pasteboard)

        let types = pasteboard.types ?? []
        XCTAssertTrue(
            types.contains(SensitiveClipboard.concealedType),
            "clipboard managers read the concealed marker to skip archiving a secret"
        )
        XCTAssertTrue(types.contains(SensitiveClipboard.transientType))
        XCTAssertTrue(types.contains(.string), "the markers must not displace the real type")
    }

    func testWriteReportsTheExpiryWindow() {
        let window = SensitiveClipboard.write("x", pasteboard: pasteboard)
        XCTAssertEqual(window, SensitiveClipboard.autoClearAfter)
    }

    func testTheExpiryNoteNamesTheDelay() {
        XCTAssertTrue(
            SensitiveClipboard.expiryNote.contains("\(Int(SensitiveClipboard.autoClearAfter))"),
            "the user is told how long they have, got: \(SensitiveClipboard.expiryNote)"
        )
    }

    func testTheWindowIsShortButUsable() {
        XCTAssertLessThanOrEqual(
            SensitiveClipboard.autoClearAfter, 60,
            "de-anonymized PII should not sit on the clipboard for minutes"
        )
        XCTAssertGreaterThanOrEqual(
            SensitiveClipboard.autoClearAfter, 15,
            "too short and the paste fails while the user is switching apps"
        )
    }

    // MARK: - Auto-clear

    func testClearRemovesOurOwnValue() {
        SensitiveClipboard.write("Jane Aoife Smith", pasteboard: pasteboard)
        let stamp = pasteboard.changeCount

        let cleared = SensitiveClipboard.clearIfUnchanged(pasteboard, expectedChangeCount: stamp)

        XCTAssertTrue(cleared)
        XCTAssertNil(
            pasteboard.string(forType: .string),
            "the de-anonymized value must not remain readable by other apps"
        )
    }

    func testClearLeavesALaterCopyAlone() {
        // The failure this guards against: the user copies something of their
        // own during the window, and our timer wipes it. Silently destroying the
        // user's clipboard would be a worse bug than the exposure.
        SensitiveClipboard.write("Jane Aoife Smith", pasteboard: pasteboard)
        let stamp = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString("something the user copied", forType: .string)

        let cleared = SensitiveClipboard.clearIfUnchanged(pasteboard, expectedChangeCount: stamp)

        XCTAssertFalse(cleared)
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "something the user copied",
            "a later copy by the user must survive our auto-clear"
        )
    }

    func testClearIsSafeToRepeat() {
        SensitiveClipboard.write("x", pasteboard: pasteboard)
        let stamp = pasteboard.changeCount
        XCTAssertTrue(SensitiveClipboard.clearIfUnchanged(pasteboard, expectedChangeCount: stamp))
        // The first clear bumps changeCount, so a second attempt with the old
        // stamp is a no-op rather than an error.
        XCTAssertFalse(SensitiveClipboard.clearIfUnchanged(pasteboard, expectedChangeCount: stamp))
    }
}
