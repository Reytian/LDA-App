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

    // MARK: - The ask page

    func testOnboardingCarriesTheAskAndItsThreeAnswers() throws {
        let view = try source("OnboardingView.swift")
        let copy = try source("ModelSetupPresentation.swift")
        XCTAssertTrue(copy.contains("Choose a detection model"))
        // The primary action reads "Download and Use" now: the size moved to
        // the rung's facts line (ModelAnnotation.localizedFacts, still read
        // from Models.json so the number cannot fork from the manifest), so
        // it is not typed twice between the button and the row beneath it.
        XCTAssertTrue(copy.contains("Download and Use"))
        XCTAssertTrue(
            view.contains("ModelAnnotation.localizedFacts("),
            "the size on each rung must come from the tier, not from a literal"
        )
        XCTAssertTrue(view.contains("I Already Have the File"))
        XCTAssertTrue(view.contains("Not Now"))
        XCTAssertTrue(
            view.contains("interactiveDismissDisabled"),
            "the ask must have no exit that is not an answer"
        )
        XCTAssertTrue(
            view.contains("recordModelSetupAnswer"),
            "the answer is recorded on the button, not inferred from a dismissal"
        )
        XCTAssertTrue(
            view.contains("onOpenModelManagement"),
            "the import route must reach Manage Models rather than describing "
                + "where it is"
        )
        XCTAssertFalse(
            view.contains("onSetUpModel"),
            "the old single-purpose closure is gone: the shell now defers the "
                + "sheet to onDismiss instead of swapping sheets in one tick"
        )
    }

    func testTheAskOnlyRendersWhenThereIsNoModel() throws {
        let text = try source("OnboardingView.swift")
        XCTAssertTrue(
            text.contains("if !hasModel"),
            "someone with a model must not be told to add one"
        )
        // The literal ternary that used to decide the first page is gone;
        // OnboardingPageModelTests.testFirstPageAndNextPage tests the pure
        // functions (OnboardingPresentation.firstPage/nextPage) directly,
        // which is a stronger check than grepping the view's source for one
        // spelling of the same decision.
    }

    func testOnboardingNamesBothPathsSoTheOfflineOneIsDiscoverable() throws {
        // The online route is a button now, so the sentence that described it
        // is retired. The offline route still needs its sentence, because a
        // firm with offline mode forced on has no other way to learn it. Both
        // now live in ModelSetupPresentation.provenanceLine rather than in
        // the view, and stay on screen through every download phase (#26/#27
        // in the wizard spec), not only while idle.
        let text = try source("OnboardingView.swift")
        XCTAssertTrue(text.contains("I Already Have the File"))
        XCTAssertTrue(text.contains("ModelSetupPresentation.provenanceLine("))

        let download = ModelSetupPresentation.provenanceLine(
            route: .download, hostDescription: "huggingface.co", language: .english
        )
        XCTAssertTrue(download.contains("huggingface.co"), download)
        XCTAssertTrue(download.contains("another Mac"), download)

        let importOnly = ModelSetupPresentation.provenanceLine(
            route: .importOnly, hostDescription: "huggingface.co", language: .english
        )
        XCTAssertTrue(importOnly.contains("Offline mode is on"), importOnly)
        XCTAssertTrue(importOnly.contains("another Mac"), importOnly)

        XCTAssertFalse(
            text.contains("Online, and quickest"),
            "the button IS the online route; a sentence describing it is stale"
        )
    }

    func testReturnStartsTheModelRatherThanDismissingTheAsk() throws {
        // The keyboard's failure direction must point at the model. Before
        // this change the footer's Get Started owned the default action on
        // both pages, so one Return reached a names-blind scan.
        //
        // Asserted on askActions rather than on modelAskPage's own body: the
        // actions are extracted into their own property (page 1 has three
        // buttons plus a phase-driven progress line), which is where the
        // shortcut lives.
        let text = try source("OnboardingView.swift")
        let actions = try XCTUnwrap(
            text.range(of: "private var askActions"),
            "askActions is missing"
        )
        let steps = try XCTUnwrap(
            text.range(of: "private var stepsPage"),
            "stepsPage is missing"
        )
        let askBody = text[actions.lowerBound..<steps.lowerBound]
        XCTAssertTrue(
            askBody.contains(".keyboardShortcut(.defaultAction)"),
            "the ask's primary answer must own the default action"
        )
        XCTAssertFalse(
            askBody.contains("Get Started"),
            "Get Started belongs to the steps page"
        )
        let stepsBody = text[steps.lowerBound...]
        XCTAssertTrue(stepsBody.contains("Get Started"))
        XCTAssertEqual(
            text.components(separatedBy: "Get Started").count - 1, 1,
            "Get Started must exist once, on the steps page"
        )
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
        // The copy moved into a pure presentation type so it can be asserted
        // as strings rather than as source; the ban loop still runs over both
        // files, because either one is where a totalising claim would land.
        let copy = try source("ModelSetupPresentation.swift")
        XCTAssertTrue(
            copy.contains("they are not in the review list"),
            "the consequence must be stated plainly, not implied"
        )
        XCTAssertTrue(
            copy.contains("still identifies your client"),
            "the reader has to know what the redacted copy still gives away"
        )
        for text in [copy, try source("OnboardingView.swift")] {
            for claim in ["all sensitive information", "guaranteed", "100%"] {
                XCTAssertFalse(text.contains(claim))
            }
        }
    }

    // MARK: - Every new string reaches the catalogs

    func testEverySetupStringIsTranslatedInAllFourCatalogs() throws {
        let keys = [
            "Step %lld of %lld",
            "Choose a detection model",
            "Only a detection model finds the names of people and organisations. Without one, those names stay in the document, they are not in the review list, and the copy you hand to an AI tool still identifies your client.",
            "Recommended",
            "Recommended: it fits this Mac with room to spare and leaves the least to dismiss.",
            "Recommended because offline mode is on.",
            "Runs on every Mac LDA supports. About one flag in five is one you will dismiss.",
            "Misses as little as Quick, with a third as much to dismiss.",
            "Missed nothing in testing, including the Chinese bank branch name Balanced missed. About twice the wait of Balanced.",
            "No model runs. The names of people and organisations are not detected.",
            "This Mac has %lld GB of memory, so %@ cannot run here.",
            "Download and Use",
            "Downloading connects to %@. If that is unreachable, add a file you got on another Mac.",
            "Offline mode is on, so downloads are off. You can still add a file you got on another Mac.",
            "No model runs. In our own test on two agreements, a scan with no model missed 32 of the 36 names, organisations, and addresses. Fixed formats are still found, and LDA asks again before the first scan of each document.",
            "Downloading the detection model.",
            "Installed and in use. Scans will now find the names of people and organisations.",
            "LDA protects client information before it reaches an AI tool, and puts it back afterwards.",
            "This Mac cannot run a detection model",
            "This Mac does not have the memory to run a detection model, so LDA does not offer one here. Scans on this Mac match patterns only, and names and company names stay in the document. Adding a model file by hand would not change that.",
            "Drop Word, PDF, or text files (or a .zip). The app scans each one and you review what it will protect. Which kinds of value it can find depends on the detection model above.",
            "I Already Have the File\u{2026}"
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
        // Matched without the closing paren: both calls now pass the
        // once-loaded catalog rather than re-reading Models.json on every body
        // pass, so the argument list is not empty.
        XCTAssertTrue(
            text.contains("AISettings.hasAnyModelAvailable("),
            "onboarding asks whether this Mac has ANY model, so a deliberate "
                + "patterns-only user with a model is not told to add one"
        )
        XCTAssertTrue(
            text.contains("AISettings.isModelMissing("),
            "the pre-scan advisory asks about the SELECTED rung, so a "
                + "deliberate patterns-only run is not nagged"
        )
        XCTAssertFalse(
            text.contains("AISettings.isModelMissing()"),
            "the body must not fall back to the reloading default catalog: "
                + "the importer publishes while a copy runs, so that would put "
                + "a disk read and a JSON parse on every progress update"
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
        let body = text[start.lowerBound...].prefix(1_200)
        XCTAssertFalse(
            body.contains("Dismiss"),
            "the advisory must hold while the condition holds"
        )
        XCTAssertTrue(body.contains("Set Up a Model"))
        // The shared chrome carries no dismiss affordance either, so neither
        // advisory can acquire one by editing one place.
        let row = try source("AdvisoryRow.swift")
        XCTAssertFalse(row.contains("Dismiss"))
        XCTAssertFalse(row.contains("isPresented"))
    }
}
