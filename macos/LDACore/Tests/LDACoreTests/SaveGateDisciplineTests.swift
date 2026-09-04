//
//  SaveGateDisciplineTests.swift
//  LDACoreTests
//
//  A source scan, because the claim being guarded is about the SHAPE of the
//  code and no behavioral probe can observe it: that no entry point reads a
//  save gate as a bare Bool, and that no entry point refuses a save without
//  saying why.
//
//  The trap this exists to stop is specific and has already happened here.
//  Repairing the toolbar while leaving ExportFlow's
//  `guard model.canExport else { return }` in place LOOKS fixed and still
//  swallows the Cmd+E menu command, which is the worst version of this bug:
//  the user asked with the keyboard, where there is no dark button to warn
//  them, and got nothing at all.
//
//  Comments are stripped before scanning, so a comment may name the retired
//  Bools when explaining what a gate used to be.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest

final class SaveGateDisciplineTests: XCTestCase {

    /// The Bool gates this refactor retired. Each was read by several entry
    /// points, and each could only ever answer no.
    private static let retiredBoolGates = [
        "canExport",
        "canSaveWorkspace",
        "canExportComplianceReport"
    ]

    /// The files that own a `report` channel into the shell's banner, so a
    /// refusal there can and must be spoken.
    private static let flowsThatMustExplainThemselves = [
        "ExportFlow.swift",
        "WorkspaceFlow.swift",
        "ComplianceReportFlow.swift"
    ]

    // MARK: - No bare Bool gate

    func testNoSaveGateIsReadAsABareBool() throws {
        var offenders: [String: [String]] = [:]
        for (file, text) in try Self.swiftSources() {
            let code = Self.strippingComments(text)
            for gate in Self.retiredBoolGates where Self.mentions(gate, in: code) {
                offenders[file, default: []].append(gate)
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "a retired Bool save gate is back: \(offenders). Every gate answers "
                + "with SaveAvailability so the blocked answer carries a reason; "
                + "read `.isAvailable` off the availability property instead of "
                + "reintroducing a Bool that can only say no."
        )
    }

    /// The availability properties that replaced them must actually exist,
    /// or the assertion above would pass on an app with no gates at all.
    func testEverySaveGateExistsAsAnAvailabilityProperty() throws {
        let expected = [
            ("ReviewModel.swift", "public var exportAvailability: SaveAvailability"),
            ("SessionModel+Workspace.swift", "public var workspaceAvailability: SaveAvailability"),
            ("SessionModel.swift", "public var exportForAIAvailability: SaveAvailability"),
            (
                "SessionModel+ComplianceReport.swift",
                "public var complianceReportAvailability: SaveAvailability"
            )
        ]
        for (file, declaration) in expected {
            let text = try Self.uiSource(file)
            XCTAssertTrue(
                text.contains(declaration),
                "\(file) must declare \(declaration)"
            )
        }
    }

    // MARK: - No silent refusal

    /// Every `isAvailable` guard that returns, listed by file. Pinned as an
    /// equality rather than a ceiling, exactly like the localization budget:
    /// a NEW bare return in any flow fails this outright, and the one
    /// remaining site has to justify itself in the assertion message below.
    func testASaveRefusalIsNeverSilent() throws {
        var bareGuards: Set<String> = []
        for (file, text) in try Self.swiftSources() {
            let code = Self.strippingComments(text)
            if Self.bareAvailabilityGuardRegex.firstMatch(
                in: code,
                range: NSRange(location: 0, length: (code as NSString).length)
            ) != nil {
                bareGuards.insert(file)
            }
        }

        XCTAssertEqual(
            bareGuards, ["ReviewModel.swift"],
            "a save refusal returned without saying why. Report the reason "
                + "through the shell's banner: "
                + "`report(SaveAvailabilityPresentation.notice(availability))`. "
                + "ReviewModel.requestExport is the ONE allowed bare return: it "
                + "owns no message channel, and the reason it would print is "
                + "derived from the same status the banner is already rendering, "
                + "so the answer is on screen before the user asks."
        )

        // The premise of that exception: the banner really does render it.
        let banner = try Self.uiSource("AppShellStatusBanner.swift")
        XCTAssertTrue(
            banner.contains("SaveAvailabilityPresentation.notice("),
            "the status banner must render the reason, or ReviewModel's bare "
                + "return has nothing standing behind it"
        )
        XCTAssertTrue(
            banner.contains("model.exportAvailability"),
            "the banner must read the SAME availability value the toolbar "
                + "button disables on, so the sentence and the dark button "
                + "cannot disagree"
        )
    }

    func testEveryFlowWithAReportChannelSpeaksTheReason() throws {
        for file in Self.flowsThatMustExplainThemselves {
            let text = try Self.uiSource(file)
            XCTAssertTrue(
                text.contains("report(SaveAvailabilityPresentation.notice("),
                "\(file) refuses a save without reporting the reason"
            )
        }
    }

    /// Export for AI has no `report` closure of its own; it returns an
    /// outcome, so the reason has to travel in the outcome or it is lost at
    /// the boundary.
    func testTheExportForAIRefusalCarriesItsReasonOutOfTheFlow() throws {
        let flow = try Self.uiSource("ExportForAIFlow.swift")
        XCTAssertTrue(
            flow.contains("case nothingReady(SaveBlockReason)"),
            "the refusal outcome must carry the reason"
        )
        let shell = try Self.uiSource("AppShell.swift")
        XCTAssertTrue(
            shell.contains("case .nothingReady(let reason)")
                && shell.contains("SaveAvailabilityPresentation.sentence(for: reason)"),
            "the shell must render the reason it was handed rather than one "
                + "fixed sentence for every blocked state"
        )
    }

    /// The four toolbar buttons stay disabled. This is not an oversight to be
    /// tidied later: an enabled button that fails is worse than a dark one
    /// that is explained.
    func testTheToolbarButtonsStayDisabledAndReadTheAvailabilityType() throws {
        let toolbar = try Self.uiSource("AppShellToolbar.swift")
        for gate in [
            "model.exportAvailability.isAvailable",
            "session.workspaceAvailability.isAvailable",
            "session.exportForAIAvailability.isAvailable",
            "session.complianceReportAvailability.isAvailable"
        ] {
            XCTAssertTrue(
                toolbar.contains(".disabled(!\(gate))"),
                "the toolbar must disable on \(gate)"
            )
        }
    }

    /// The menu commands are the path with no button to look at, so they must
    /// read the same gates rather than a local re-derivation.
    func testTheMenuCommandsReadTheSameGates() throws {
        let app = try Self.appSource("LDAApp.swift")
        for gate in [
            "sessionModel.activeModel.exportAvailability.isAvailable",
            "sessionModel.exportForAIAvailability.isAvailable"
        ] {
            XCTAssertTrue(app.contains(gate), "LDAApp must gate on \(gate)")
        }
    }

    // MARK: - Scanning

    /// `guard <anything> isAvailable ... else { return }` with nothing between
    /// the brace and the return: a refusal that says nothing.
    private static let bareAvailabilityGuardRegex = try! NSRegularExpression(
        pattern: #"guard[^\n]*isAvailable[^\n]*else\s*\{\s*return\s*\}"#
    )

    /// A gate name as an identifier, so `canExport` does not match
    /// `canExportComplianceReport` and vice versa; both are listed
    /// explicitly.
    private static func mentions(_ gate: String, in code: String) -> Bool {
        let regex = try! NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])\#(gate)(?![A-Za-z0-9_])"#
        )
        let range = NSRange(location: 0, length: (code as NSString).length)
        return regex.firstMatch(in: code, range: range) != nil
    }

    /// Blanks `//` and `/* */` comment bodies, tracking string-literal state
    /// so a `//` inside a literal is not read as a comment. Newlines are
    /// preserved so the scanned text still lines up with the source.
    static func strippingComments(_ text: String) -> String {
        var units = Array(text.utf16)
        let quote: UInt16 = 34, backslash: UInt16 = 92
        let slash: UInt16 = 47, star: UInt16 = 42
        let newline: UInt16 = 10, space: UInt16 = 32

        var i = 0
        var inString = false
        var inBlockComment = false
        while i < units.count {
            if inBlockComment {
                if i + 1 < units.count, units[i] == star, units[i + 1] == slash {
                    units[i] = space
                    units[i + 1] = space
                    i += 2
                    inBlockComment = false
                } else {
                    if units[i] != newline { units[i] = space }
                    i += 1
                }
                continue
            }
            if inString {
                if units[i] == backslash, i + 1 < units.count {
                    i += 2
                    continue
                }
                if units[i] == quote { inString = false }
                i += 1
                continue
            }
            if i + 1 < units.count, units[i] == slash, units[i + 1] == slash {
                var j = i
                while j < units.count, units[j] != newline {
                    units[j] = space
                    j += 1
                }
                i = j
                continue
            }
            if i + 1 < units.count, units[i] == slash, units[i + 1] == star {
                units[i] = space
                units[i + 1] = space
                i += 2
                inBlockComment = true
                continue
            }
            if units[i] == quote {
                inString = true
                i += 1
                continue
            }
            i += 1
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    // MARK: - File access

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func uiSource(_ name: String) throws -> String {
        try source(at: packageRoot
            .appendingPathComponent("Sources/LDAUI", isDirectory: true)
            .appendingPathComponent(name))
    }

    private static func appSource(_ name: String) throws -> String {
        try source(at: packageRoot
            .appendingPathComponent("Sources/LDAApp", isDirectory: true)
            .appendingPathComponent(name))
    }

    private static func source(at url: URL) throws -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(url.lastPathComponent) is missing; this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        return text
    }

    /// Every Swift file in both UI targets, so a gate reader cannot hide in a
    /// file this test did not think to name.
    private static func swiftSources() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        for directory in ["Sources/LDAUI", "Sources/LDAApp"] {
            let root = packageRoot.appendingPathComponent(directory, isDirectory: true)
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil
            ) else {
                XCTFail("could not walk \(root.path)")
                throw CocoaError(.fileNoSuchFile)
            }
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append((url.lastPathComponent, text))
            }
        }
        XCTAssertFalse(out.isEmpty, "the scan found no source at all; check the path")
        return out
    }
}
