//
//  ModelSetupDialogSafetyTests.swift
//  LDACoreTests
//
//  The keyboard safety property of the two model gate dialogs: a keypress must
//  never be the thing that discloses.
//
//  Why this file exists. The header of ModelSetupFlow claimed "Both dialogs
//  offer the fix first, so an accidental Return spends bandwidth and never
//  confidentiality", and that was false of the export dialog, which listed
//  Export Anyway first and carried no fix button at all. So on the one dialog
//  guarding an actual disclosure, the first button wrote a copy that still
//  held people's names. Order is also not a safety property by itself: it is
//  not established that SwiftUI's macOS confirmationDialog binds Return to the
//  first listed button, and the sibling dialog in ClientMatterFlow lists a
//  destructive action first with no shortcut at all.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

// The cancel button is matched as L10n.button("Cancel", not Button("Cancel":
// the dialog's copy routes through L10n so it follows the language picker.
// The keypress assertions are unchanged; only the spelling of the anchor is.
final class ModelSetupDialogSafetyTests: XCTestCase {

    private func uiSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LDAUI")
            .appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(name) is missing; this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        return text
    }

    /// One dialog's slice of `ModelSetupFlow.body`, bounded by its own title
    /// and message expressions so neither dialog's assertions can be satisfied
    /// by the other one's buttons.
    private func dialogBlock(
        _ text: String,
        from opening: String,
        to closing: String
    ) throws -> String {
        let start = try XCTUnwrap(
            text.range(of: opening),
            "the dialog opening \(opening) is missing"
        )
        let end = try XCTUnwrap(
            text.range(of: closing, range: start.upperBound..<text.endIndex),
            "the dialog closing \(closing) is missing"
        )
        return String(text[start.lowerBound..<end.upperBound])
    }

    private func scanBlock(_ text: String) throws -> String {
        try dialogBlock(text, from: "Text(verbatim: scan.title)", to: "Text(verbatim: scan.message)")
    }

    private func exportBlock(_ text: String) throws -> String {
        try dialogBlock(text, from: "Text(verbatim: export.title)", to: "Text(verbatim: export.message)")
    }

    /// Assert that `subject` appears before `other` in `block`.
    private func assertPrecedes(
        _ subject: String,
        _ other: String,
        in block: String,
        _ message: String
    ) throws {
        let first = try XCTUnwrap(block.range(of: subject), "\(subject) is missing")
        let second = try XCTUnwrap(block.range(of: other), "\(other) is missing")
        XCTAssertTrue(first.lowerBound < second.lowerBound, message)
    }

    // MARK: - The decision, behaviourally

    func testTheReturnDefaultBelongsToTheFixOrElseToCancel() {
        XCTAssertEqual(
            ModelSetupPresentation.gateDefault(offersFix: true),
            .fix,
            "where a remedy exists, Return spends bandwidth"
        )
        XCTAssertEqual(
            ModelSetupPresentation.gateDefault(offersFix: false),
            .cancel,
            "a Mac that can run no model never reaches the scan gate but does "
                + "reach the export gate, and there the safe path still has to "
                + "be the keypress"
        )
        // The property stated as a property: whatever the machine, the Return
        // default is never the button that writes the copy.
        for offersFix in [true, false] {
            XCTAssertNotEqual(
                ModelSetupPresentation.gateDefault(offersFix: offersFix),
                ModelSetupPresentation.GateButton.proceed,
                "Return must never reach the disclosing button"
            )
        }
    }

    // MARK: - The export dialog, the one that guards a disclosure

    func testTheExportDialogOffersTheFixFirstAndBindsReturnToIt() throws {
        let block = try exportBlock(try uiSource("ModelSetupFlow.swift"))

        try assertPrecedes(
            "Button(exportFixTitle)", "Button(export.proceed)", in: block,
            "the fix must come before the button that writes a copy still "
                + "carrying people's names"
        )
        try assertPrecedes(
            "Button(exportFixTitle)", ".keyboardShortcut(.defaultAction)", in: block,
            "the Return default must be attached to the fix button"
        )
        try assertPrecedes(
            ".keyboardShortcut(.defaultAction)", "Button(export.proceed)", in: block,
            "the Return default must be attached to the fix button, not to a "
                + "later one"
        )
        // Acting on the fix from here is acting on the ask, so it records the
        // answer like every other Manage Models route.
        XCTAssertTrue(
            block.contains("AISettings.recordModelSetupAnswer(.accepted)"),
            "a stored decline must not survive the user acting to fix it"
        )
    }

    func testTheDisclosingButtonCarriesNoKeypressInEitherDialog() throws {
        let text = try uiSource("ModelSetupFlow.swift")
        for (name, block, proceed) in [
            ("scan", try scanBlock(text), "Button(scan.proceed)"),
            ("export", try exportBlock(text), "Button(export.proceed)")
        ] {
            let start = try XCTUnwrap(block.range(of: proceed))
            let cancel = try XCTUnwrap(
                block.range(of: "L10n.button(\"Cancel\"", range: start.upperBound..<block.endIndex),
                "\(name): the cancel button is missing"
            )
            XCTAssertFalse(
                block[start.upperBound..<cancel.lowerBound].contains("keyboardShortcut"),
                "\(name): the button that proceeds must not own a keypress"
            )
        }
    }

    func testCancelOwnsAKeypressInBothDialogs() throws {
        let text = try uiSource("ModelSetupFlow.swift")
        let scan = try scanBlock(text)
        try assertPrecedes(
            "L10n.button(\"Cancel\"", ".keyboardShortcut(.cancelAction)", in: scan,
            "escape must reach cancel explicitly, not by inference from the role"
        )
        // The export dialog's cancel takes the Return default too on a Mac
        // where no fix can be offered, so its shortcut is chosen rather than
        // fixed.
        let export = try exportBlock(text)
        try assertPrecedes(
            "L10n.button(\"Cancel\"", "exportDefault == .cancel", in: export,
            "the export dialog's cancel must own Return where there is no fix "
                + "to own it"
        )
    }

    // MARK: - The header claim

    func testTheHeaderClaimIsTrueOfBothDialogs() throws {
        let text = try uiSource("ModelSetupFlow.swift")
        let header = String(
            text[text.startIndex..<(try XCTUnwrap(text.range(of: "import SwiftUI")).lowerBound)]
        )
        XCTAssertTrue(
            header.contains("Return"),
            "the header states a keyboard safety property, so it must name the "
                + "keypress it is about"
        )
        XCTAssertTrue(
            header.contains("Cancel owns Return"),
            "the claim has to be scoped honestly: on a Mac that can run no "
                + "model the export gate has no fix button, and Cancel is what "
                + "Return reaches there"
        )
        XCTAssertFalse(
            header.contains("Both dialogs offer the fix first, so an accidental Return"),
            "the order-only claim was false of the export dialog and must not "
                + "come back without the explicit binding behind it"
        )
    }
}
