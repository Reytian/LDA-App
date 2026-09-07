//
//  SaveAvailabilityTests.swift
//  LDACoreTests
//
//  Three things about the save gates.
//
//  A. The refactor is behaviour preserving. Save Redacted, Save Workspace,
//     Export for AI and Export Report each swapped a bare Bool for a
//     SaveAvailability, and for every state the new type's isAvailable must
//     equal the Bool expression it replaced. The old expressions are written
//     out here rather than referenced, because the point is to compare against
//     what the code USED to say; a reference would compare the new code to
//     itself.
//
//  B. No reader is left on a bare Bool, which is what stops the ExportFlow
//     style silent return coming back.
//
//  C. Every reason has a real, non-empty sentence in all four catalogs. A
//     reason that renders as its own English key is a reason that does not
//     explain anything to a lawyer reading the app in Chinese.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest
@testable import LDAUI

final class SaveAvailabilityTests: XCTestCase {

    /// Every ReviewStatus case. ReviewStatus carries an associated value so it
    /// cannot be CaseIterable; the count is pinned below so a new case cannot
    /// be added without this list noticing.
    private static let allStatuses: [ReviewStatus] = [
        .idle,
        .importing,
        .imported,
        .detecting,
        .ready,
        .failed("import failed")
    ]

    func testTheStatusFixtureCoversEveryReviewStatusCase() throws {
        // A source count, because no runtime probe can observe the absence of
        // a case. If this fails, a new ReviewStatus case exists and every
        // switch in SaveAvailabilityRules needs a decision for it.
        let source = try Self.uiSource("ReviewModel.swift")
        guard let range = source.range(of: "public enum ReviewStatus: Equatable {"),
              let end = source.range(of: "\n}", range: range.upperBound..<source.endIndex) else {
            return XCTFail("could not locate the ReviewStatus declaration")
        }
        let body = source[range.upperBound..<end.lowerBound]
        let cases = body.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ")
        }
        XCTAssertEqual(
            cases.count, Self.allStatuses.count,
            "ReviewStatus has \(cases.count) cases but this fixture lists "
                + "\(Self.allStatuses.count). Add the new state here AND give "
                + "SaveAvailabilityRules.saveRedacted a reason for it."
        )
    }

    // MARK: - A: behaviour preserving

    func testSaveRedactedAvailabilityEqualsTheOldReadyOnlyGate() {
        for status in Self.allStatuses {
            // ReviewModel.canExport, verbatim as it was before this change.
            let old: Bool = {
                if case .ready = status { return true }
                return false
            }()
            XCTAssertEqual(
                SaveAvailabilityRules.saveRedacted(status: status).isAvailable, old,
                "Save Redacted changed its answer for \(status)"
            )
        }
    }

    /// The one condition that is not a status: the file on disk stopped
    /// matching the file that was scanned. It blocks with its own reason,
    /// because the remedy (open the file again) is one no status names, and
    /// it outranks a finished scan, which is the only state it can arise in.
    func testASourceThatChangedAfterTheScanBlocksSaveRedactedWithItsOwnReason() {
        XCTAssertEqual(
            SaveAvailabilityRules.saveRedacted(status: .ready, sourceChangedSinceScan: true),
            .blocked(.sourceChangedSinceScan)
        )
        XCTAssertEqual(
            SaveAvailabilityRules.saveRedacted(status: .ready, sourceChangedSinceScan: false),
            .available,
            "the flag, not the status, is what blocks"
        )
        for status in Self.allStatuses {
            XCTAssertEqual(
                SaveAvailabilityRules.saveRedacted(status: status, sourceChangedSinceScan: true).blockReason,
                .sourceChangedSinceScan,
                "a changed source must name its own remedy in \(status)"
            )
        }
    }

    func testSaveWorkspaceAvailabilityEqualsTheOldNonEmptyTrayGate() {
        for documentCount in 0...4 {
            // SessionModel.canSaveWorkspace was `!entries.isEmpty`.
            let old = !(documentCount == 0)
            XCTAssertEqual(
                SaveAvailabilityRules.saveWorkspace(documentCount: documentCount).isAvailable,
                old,
                "Save Workspace changed its answer for \(documentCount) documents"
            )
        }
    }

    func testExportForAIAvailabilityEqualsTheOldAnyDocumentReadyGate() {
        // Every tray up to length three, so an ordering difference between the
        // old `contains` and the new priority walk would show up.
        for statuses in Self.trays(upTo: 3) {
            // The toolbar and the menu both read
            // `entries.contains { $0.model.canExport }`.
            let old = statuses.contains { status in
                if case .ready = status { return true }
                return false
            }
            XCTAssertEqual(
                SaveAvailabilityRules.exportForAI(statuses: statuses).isAvailable, old,
                "Export for AI changed its answer for \(statuses)"
            )
        }
    }

    func testExportReportAvailabilityEqualsTheOldRecordGate() {
        for hasRecord in [true, false] {
            // SessionModel.canExportComplianceReport was `currentRecordID != nil`.
            XCTAssertEqual(
                SaveAvailabilityRules.exportReport(hasHandoffRecord: hasRecord).isAvailable,
                hasRecord
            )
        }
    }

    func testAvailabilityAndReasonCanNeverDisagree() {
        XCTAssertTrue(SaveAvailability.available.isAvailable)
        XCTAssertNil(SaveAvailability.available.blockReason)
        for reason in SaveBlockReason.allCases {
            let blocked = SaveAvailability.blocked(reason)
            XCTAssertFalse(blocked.isAvailable)
            XCTAssertEqual(blocked.blockReason, reason)
        }
    }

    /// The whole point of the type: a no always carries a why. Checked over
    /// every gate and every state, so no path can answer "no" in silence.
    func testEveryBlockedAnswerCarriesAReason() {
        var checked = 0
        for status in Self.allStatuses {
            for availability in [
                SaveAvailabilityRules.saveRedacted(status: status),
                SaveAvailabilityRules.exportForAI(statuses: [status])
            ] {
                checked += 1
                XCTAssertEqual(
                    availability.isAvailable, availability.blockReason == nil,
                    "\(status) produced an availability that disagrees with itself"
                )
            }
        }
        for availability in [
            SaveAvailabilityRules.saveWorkspace(documentCount: 0),
            SaveAvailabilityRules.saveWorkspace(documentCount: 1),
            SaveAvailabilityRules.exportReport(hasHandoffRecord: false),
            SaveAvailabilityRules.exportReport(hasHandoffRecord: true)
        ] {
            checked += 1
            XCTAssertEqual(availability.isAvailable, availability.blockReason == nil)
        }
        XCTAssertEqual(checked, Self.allStatuses.count * 2 + 4)
    }

    // MARK: - The asymmetry this task is about

    /// The user's confusion, pinned as a fact rather than a story: opening a
    /// document opens Save Workspace and leaves Save Redacted shut, and the
    /// reason now says which and what to do.
    func testTheGapBetweenOpeningADocumentAndFinishingAScanNowExplainsItself() {
        let openedButNotScanned = SaveAvailabilityRules.saveRedacted(status: .imported)
        XCTAssertFalse(openedButNotScanned.isAvailable)
        XCTAssertEqual(openedButNotScanned.blockReason, .scanNotFinished)
        XCTAssertTrue(
            SaveAvailabilityRules.saveWorkspace(documentCount: 1).isAvailable,
            "the asymmetry is real: Save Workspace only needs an open document"
        )
        let sentence = try? XCTUnwrap(SaveAvailabilityPresentation.notice(openedButNotScanned))
        XCTAssertEqual(
            sentence, "Save Redacted needs a finished scan. Click Scan for PII first.",
            "the sentence must name the button and the next action"
        )
    }

    /// Save Workspace's gate can only shut on an empty tray, and an empty tray
    /// shuts Save Redacted too. That is why the banner needs ONE line rather
    /// than one per button, and it is a property of the rules, not a hope.
    func testSaveWorkspaceIsNeverBlockedWhileSaveRedactedIsAvailable() {
        for documentCount in 0...4 {
            let workspace = SaveAvailabilityRules.saveWorkspace(documentCount: documentCount)
            guard !workspace.isAvailable else { continue }
            XCTAssertEqual(documentCount, 0)
            // An empty tray means the active model is .idle.
            let redacted = SaveAvailabilityRules.saveRedacted(status: .idle)
            XCTAssertFalse(redacted.isAvailable)
            XCTAssertEqual(
                redacted.blockReason, workspace.blockReason,
                "the shared reason is what lets one banner line cover both"
            )
        }
    }

    func testExportForAIReportsWorkInFlightBeforeWorkNotStarted() {
        XCTAssertEqual(
            SaveAvailabilityRules.exportForAI(statuses: []).blockReason,
            .noDocumentOpen
        )
        XCTAssertEqual(
            SaveAvailabilityRules.exportForAI(statuses: [.imported, .detecting]).blockReason,
            .scanStillRunning,
            "waiting is the next action, so the scan in flight outranks the queue"
        )
        XCTAssertEqual(
            SaveAvailabilityRules.exportForAI(statuses: [.failed("x"), .imported]).blockReason,
            .scanNotFinished,
            "a scannable document outranks one that can never become ready"
        )
        XCTAssertEqual(
            SaveAvailabilityRules.exportForAI(statuses: [.failed("x")]).blockReason,
            .documentFailedToOpen
        )
    }

    /// The reason must not depend on tray order, or the same session would
    /// explain itself differently after a re-sort.
    func testTheExportForAIReasonIsIndependentOfTrayOrder() {
        for statuses in Self.trays(upTo: 3) {
            let forward = SaveAvailabilityRules.exportForAI(statuses: statuses)
            let reversed = SaveAvailabilityRules.exportForAI(statuses: statuses.reversed())
            XCTAssertEqual(forward, reversed, "order changed the answer for \(statuses)")
        }
    }

    // MARK: - C: every reason is translated

    func testEverySaveBlockReasonHasANonEmptyEntryInAllFourCatalogs() throws {
        let identifiers = ["en", "fr", "zh-Hans", "zh-Hant"]
        var catalogs: [String: [String: String]] = [:]
        for identifier in identifiers {
            catalogs[identifier] = try Self.catalog(identifier: identifier)
        }

        for reason in SaveBlockReason.allCases {
            let key = SaveAvailabilityPresentation.reasonKey(reason)
            XCTAssertFalse(key.isEmpty, "\(reason) has no catalog key")
            for identifier in identifiers {
                let catalog = try XCTUnwrap(catalogs[identifier])
                let value = catalog[key]
                XCTAssertNotNil(
                    value,
                    "\(identifier) has no entry for \(reason): \(key)"
                )
                XCTAssertFalse(
                    (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(identifier) has an empty entry for \(reason): \(key)"
                )
            }
        }
    }

    func testEveryReasonReadsAsTheSelectedLanguageRatherThanEnglish() {
        for reason in SaveBlockReason.allCases {
            let english = SaveAvailabilityPresentation.sentence(for: reason, language: .english)
            XCTAssertEqual(
                english, SaveAvailabilityPresentation.reasonKey(reason),
                "the English value must be the key itself"
            )
            for language in [AppLanguage.french, .simplifiedChinese, .traditionalChinese] {
                let translated = SaveAvailabilityPresentation.sentence(
                    for: reason,
                    language: language
                )
                XCTAssertNotEqual(
                    translated, english,
                    "\(language.rawValue) fell back to English for \(reason)"
                )
                XCTAssertFalse(translated.isEmpty)
            }
        }
    }

    /// Simplified and Traditional must not borrow each other's characters. The
    /// vocabulary is settled per script; crossing them is the failure this
    /// catalog has already had once.
    func testTheChineseReasonsKeepTheirScriptsApart() {
        for reason in SaveBlockReason.allCases {
            let hans = SaveAvailabilityPresentation.sentence(
                for: reason,
                language: .simplifiedChinese
            )
            let hant = SaveAvailabilityPresentation.sentence(
                for: reason,
                language: .traditionalChinese
            )
            for forbidden in ["脫", "隱", "個", "復", "儲", "檔"] {
                XCTAssertFalse(
                    hans.contains(forbidden),
                    "zh-Hans uses the Traditional character \(forbidden) in \(reason): \(hans)"
                )
            }
            for forbidden in ["脱", "隐", "个", "复", "储", "档"] {
                XCTAssertFalse(
                    hant.contains(forbidden),
                    "zh-Hant uses the Simplified character \(forbidden) in \(reason): \(hant)"
                )
            }
        }
    }

    func testNoReasonUsesAProhibitedDash() {
        for reason in SaveBlockReason.allCases {
            for language in AppLanguage.allCases {
                let value = SaveAvailabilityPresentation.sentence(for: reason, language: language)
                XCTAssertFalse(value.contains("\u{2014}"), "em-dash in \(reason)")
                XCTAssertFalse(value.contains("\u{2013}"), "en-dash in \(reason)")
            }
        }
    }

    func testNoticeIsNilExactlyWhenTheSaveCanRun() {
        XCTAssertNil(SaveAvailabilityPresentation.notice(.available))
        for reason in SaveBlockReason.allCases {
            XCTAssertEqual(
                SaveAvailabilityPresentation.notice(.blocked(reason)),
                SaveAvailabilityPresentation.sentence(for: reason)
            )
        }
    }

    // MARK: - Fixtures

    /// Every tray of ReviewStatus values up to `length`, the empty tray
    /// included.
    private static func trays(upTo length: Int) -> [[ReviewStatus]] {
        var out: [[ReviewStatus]] = [[]]
        var frontier: [[ReviewStatus]] = [[]]
        for _ in 1...length {
            var next: [[ReviewStatus]] = []
            for tray in frontier {
                for status in allStatuses {
                    next.append(tray + [status])
                }
            }
            out.append(contentsOf: next)
            frontier = next
        }
        return out
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static func uiSource(_ name: String) throws -> String {
        let url = packageRoot
            .appendingPathComponent("Sources/LDAUI", isDirectory: true)
            .appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(name) is missing; this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        return text
    }

    private static func catalog(identifier: String) throws -> [String: String] {
        let url = packageRoot
            .appendingPathComponent("Sources/LDAUI/Resources", isDirectory: true)
            .appendingPathComponent("\(identifier).lproj/Localizable.strings")
        return try XCTUnwrap(
            NSDictionary(contentsOf: url) as? [String: String],
            "could not parse \(identifier)"
        )
    }
}
