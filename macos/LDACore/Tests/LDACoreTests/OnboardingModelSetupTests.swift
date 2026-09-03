//
//  OnboardingModelSetupTests.swift
//  LDACoreTests
//
//  First run on a model-less install. No model ships inside the app any more,
//  so "add a detection model" is the default first-run state rather than an
//  edge case, and it has to be a step the user can act on rather than a red
//  warning appended after the privacy block.
//
//  Following this suite's neighbours, the assertions land on the pure
//  presentation helpers and on the source of the view, because a rendered
//  SwiftUI body is not inspectable here.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest
@testable import LDAUI

@MainActor
final class OnboardingModelSetupTests: XCTestCase {

    private static var uiSources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LDAUI", isDirectory: true)
    }

    private func source(_ name: String) throws -> String {
        let url = Self.uiSources.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(name) is missing; this check must not be skipped")
            throw CocoaError(.fileNoSuchFile)
        }
        return text
    }

    // MARK: - The setup step

    func testOnboardingCarriesTheSetupBlockAndItsButton() throws {
        let text = try source("OnboardingView.swift")
        XCTAssertTrue(text.contains("First, add a detection model"))
        XCTAssertTrue(text.contains("Set Up a Model"))
        XCTAssertTrue(
            text.contains("onSetUpModel"),
            "the button must route to Manage Models rather than describing where it is"
        )
    }

    func testTheSetupBlockOnlyRendersWhenThereIsNoModel() throws {
        let text = try source("OnboardingView.swift")
        XCTAssertTrue(
            text.contains("if !hasModel"),
            "someone with a model must not be told to add one"
        )
    }

    func testOnboardingNamesBothPathsSoTheOfflineOneIsDiscoverable() throws {
        // One button, two labelled sentences. Two buttons would both land in
        // the same sheet, so one of them would not do what it said.
        let text = try source("OnboardingView.swift")
        XCTAssertTrue(text.contains("Online, and quickest"))
        XCTAssertTrue(text.contains("No connection:"))
    }

    func testOnboardingNoLongerSendsTheUserHuntingThroughSettings() throws {
        let text = try source("OnboardingView.swift")
        XCTAssertFalse(
            text.contains("Open Settings, then AI, to choose and install a model."),
            "the old warning asked a first-time user to navigate chrome they "
                + "have not seen yet; the setup button replaces it"
        )
    }

    func testOnboardingNoLongerClaimsTheModelShipsInsideTheApp() throws {
        let text = try source("OnboardingView.swift")
        XCTAssertFalse(text.contains("Quick ships inside the app"))
        XCTAssertFalse(text.contains("package-app.sh refuses to produce"))
    }

    // MARK: - Setup copy is enumerated, never totalising

    func testSetupCopyEnumeratesWhatPatternsFindAndWhatTheyDoNot() throws {
        let text = try source("OnboardingView.swift")
        XCTAssertTrue(
            text.contains(
                "Names, companies, and addresses are not detected and stay in the document."
            ),
            "the consequence must be stated plainly, not implied"
        )
        for claim in ["all sensitive information", "guaranteed", "100%"] {
            XCTAssertFalse(text.contains(claim))
        }
    }

    // MARK: - Every new string reaches the catalogs

    func testEverySetupStringIsTranslatedInAllFourCatalogs() throws {
        let keys = [
            "First, add a detection model",
            "LDA needs a detection model on this Mac to find names, companies, and addresses. Until you add one, a scan finds only what patterns can match: emails, phones, dates, amounts, ID numbers, and case numbers. Names, companies, and addresses are not detected and stay in the document.",
            "Online, and quickest: download the model from Manage Models. About 2.74 GB.",
            "No connection: download the model on another Mac, bring it over on a drive, and add the file in Manage Models. LDA checks it before installing it."
        ]
        for language in [AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese] {
            for key in keys {
                let value = L10n.string(key, language: language)
                XCTAssertFalse(value.isEmpty)
                if language != .english {
                    XCTAssertNotEqual(
                        value, key,
                        "\(language) is missing a translation for: \(key)"
                    )
                }
            }
        }
    }

    // MARK: - The two questions stay apart

    func testAppShellAsksAboutTheMachineForOnboardingAndTheRungForTheAdvisory() throws {
        let text = try source("AppShell.swift")
        XCTAssertTrue(
            text.contains("AISettings.hasAnyModelAvailable()"),
            "onboarding asks whether this Mac has ANY model, so a deliberate "
                + "patterns-only user with a model is not told to add one"
        )
        XCTAssertTrue(
            text.contains("AISettings.isModelMissing()"),
            "the pre-scan advisory asks about the SELECTED rung, so a "
                + "deliberate patterns-only run is not nagged"
        )
        XCTAssertFalse(
            text.contains("modelAvailable: model.modelPath.map"),
            "the conflated check must be gone: it is nil for a patterns-only "
                + "user too, so onboarding told them to add a model"
        )
    }

    // MARK: - The advisory is not dismissible

    func testTheMissingModelAdvisoryHasNoDismissAffordance() throws {
        // Deliberate, and the comment in the view says so: a dismissible
        // advisory means a lawyer can hide the fact that the scan does not look
        // for names before acting on its output.
        let text = try source("AppShell.swift")
        guard let start = text.range(of: "private func missingModelAdvisory") else {
            XCTFail("missingModelAdvisory is missing")
            return
        }
        let body = text[start.lowerBound...].prefix(1_600)
        XCTAssertFalse(
            body.contains("Dismiss"),
            "the advisory must hold while the condition holds"
        )
        XCTAssertTrue(body.contains("Set Up a Model"))
    }
}
