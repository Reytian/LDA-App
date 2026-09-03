//
//  ModelSetupPresentationTests.swift
//  LDACoreTests
//
//  The copy and the routing behind the model ask, the pre-scan gate and the
//  Export for AI gate.
//
//  The first test in this file is the one that matters most: it fails if a
//  future edit softens the disclosure into an accuracy claim. Precision is
//  untouched by a missing model; what disappears is three categories from the
//  search space, and "accuracy decreases" invites the reading "somewhat worse
//  but working" for a lawyer who is about to hand the copy to an AI tool.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

final class ModelSetupPresentationTests: XCTestCase {

    // MARK: - The disclosure names categories, never accuracy

    func testAskBodyNamesPersonCompanyAndAddressRatherThanAccuracy() {
        // The wizard's own sentence (askBody) states the consequence for an
        // AI handoff; the Chinese-street-form caveat and the twelve-item
        // pattern enumeration moved to the pre-scan gate (scanConfirmation),
        // which fires before any actual scan and already carries both, per
        // wizard spec decision 13. Together the two surfaces must still state
        // every clause below at least once.
        let body = ModelSetupPresentation
            .askBody(route: .download, language: .english)
            .joined(separator: " ")
            + " " + ModelSetupPresentation.scanConfirmation(language: .english).message

        for clause in [
            "names of people and organisations",
            "not in the review list",
            "still identifies your client",
            "people's names or company names",
            "Chinese street form"
        ] {
            XCTAssertTrue(
                body.contains(clause),
                "the ask flow must state: \(clause)"
            )
        }

        // The failure direction this test exists for. If someone rewrites the
        // ask as "accuracy decreases significantly", every clause above can
        // survive in spirit while the reader is told something softer and less
        // true than what the measurement supports.
        let lowered = body.lowercased()
        for softener in [
            "accuracy", "less accurate", "reduced", "may miss", "might miss", "somewhat"
        ] {
            XCTAssertFalse(
                lowered.contains(softener),
                "the disclosure must enumerate what is not looked for, not rate it: \(softener)"
            )
        }
    }

    func testAskCopyMakesNoTotalisingClaim() {
        var copy = ModelSetupPresentation.askBody(route: .download, language: .english)
        copy += ModelSetupPresentation.askBody(route: .unavailable, language: .english)
        copy.append(ModelSetupPresentation.scanConfirmation(language: .english).message)
        copy.append(
            ModelSetupPresentation
                .exportConfirmation(reason: .didNotRun, language: .english).message
        )
        copy.append(
            ModelSetupPresentation
                .exportConfirmation(reason: .ranPartially, language: .english).message
        )

        for sentence in copy {
            let lowered = sentence.lowercased()
            for claim in ["guaranteed", "100%", "all sensitive", "everything"] {
                XCTAssertFalse(
                    lowered.contains(claim),
                    "model setup copy must not claim \(claim)"
                )
            }
        }
    }

    // MARK: - Routing

    func testAskRouteDegradesToImportOnlyUnderOfflineMode() {
        XCTAssertEqual(
            ModelSetupPresentation.askRoute(canRunAModel: true, canDownload: true),
            .download
        )
        XCTAssertEqual(
            ModelSetupPresentation.askRoute(canRunAModel: true, canDownload: false),
            .importOnly,
            "offline mode blocks the download but not the verified import"
        )
        XCTAssertEqual(
            ModelSetupPresentation.askRoute(canRunAModel: false, canDownload: false),
            .unavailable
        )
        XCTAssertEqual(
            ModelSetupPresentation.askTitleKey(route: .unavailable),
            "This Mac cannot run a detection model"
        )
        XCTAssertEqual(
            ModelSetupPresentation.askTitleKey(route: .download),
            "Choose a detection model"
        )
    }

    func testDownloadButtonTitleTakesItsSizeFromTheTier() {
        let title = ModelSetupPresentation.downloadButtonTitle(
            sizeDescription: "2.74 GB",
            language: .english
        )
        XCTAssertTrue(title.contains("2.74 GB"), title)
        // No second size can hide in the string, so the number cannot fork
        // from Models.json.
        for other in ["2.7 GB", "3 GB", "13.83 GB", "About"] {
            XCTAssertFalse(title.contains(other), title)
        }
        XCTAssertEqual(
            ModelSetupPresentation.downloadButtonTitle(
                sizeDescription: "9.80 GB", language: .english
            ),
            "Download the Model (9.80 GB)"
        )
    }

    // MARK: - The export gate fires on a per-document scan-time fact

    func testExportConfirmationFiresOnlyForADocumentWhoseAIPassDidNotRun() {
        typealias Document = (
            canExport: Bool, aiRan: Bool, aiFailure: String?, aiRanPartially: Bool
        )

        XCTAssertFalse(
            ModelSetupPresentation.exportNeedsConfirmation(documents: []),
            "nothing to export, nothing to warn about"
        )
        XCTAssertFalse(
            ModelSetupPresentation.exportNeedsConfirmation(
                documents: [(canExport: false, aiRan: false, aiFailure: "no model", aiRanPartially: false)]
            ),
            "a document that cannot be exported carries nothing into the handoff"
        )
        XCTAssertFalse(
            ModelSetupPresentation.exportNeedsConfirmation(
                documents: [(canExport: true, aiRan: true, aiFailure: nil, aiRanPartially: false)]
            ),
            "the pass ran"
        )
        XCTAssertFalse(
            ModelSetupPresentation.exportNeedsConfirmation(
                documents: [(canExport: true, aiRan: false, aiFailure: nil, aiRanPartially: false)]
            ),
            "a deliberate patterns-only run is a choice, not a failure"
        )
        XCTAssertTrue(
            ModelSetupPresentation.exportNeedsConfirmation(
                documents: [(canExport: true, aiRan: false, aiFailure: "no model", aiRanPartially: false)]
            ),
            "asked for and did not run: this is the disclosure case"
        )
        // One bad document in a tray of good ones still asks.
        let mixed: [Document] = [
            (canExport: true, aiRan: true, aiFailure: nil, aiRanPartially: false),
            (canExport: true, aiRan: false, aiFailure: "no model", aiRanPartially: false),
            (canExport: true, aiRan: true, aiFailure: nil, aiRanPartially: false)
        ]
        XCTAssertTrue(ModelSetupPresentation.exportNeedsConfirmation(documents: mixed))
    }

    // MARK: - Every new string reaches all four catalogs

    func testEveryNewSetupStringIsTranslatedInAllFourCatalogs() {
        let keys = [
            // K1 and K2, the wizard's one-sentence ask body and its defer
            // row's evidence. Replaces the old three-paragraph ask body: the
            // Chinese-street-form caveat and the pattern enumeration moved to
            // the pre-scan gate (K10/K11 below), and the measured evidence
            // moved from the ask's last paragraph to the defer ("Not Now")
            // row, where the decision it informs actually is.
            "Only a detection model finds the names of people and organisations. Without one, those names stay in the document, they are not in the review list, and the copy you hand to an AI tool still identifies your client.",
            "No model runs. In our own test on two agreements, a scan with no model missed 32 of the 36 names, organisations, and addresses. Fixed formats are still found, and LDA asks again before the first scan of each document.",
            // K3 to K6, the two routes and the download progress line.
            "Download the Model (%@)",
            "I Already Have the File\u{2026}",
            "Downloading the detection model.",
            "Installed and in use. Scans will now find the names of people and organisations.",
            // K8 and K9, the Mac that cannot run one.
            "This Mac cannot run a detection model",
            "This Mac does not have the memory to run a detection model, so LDA does not offer one here. Scans on this Mac match patterns only, and names and company names stay in the document. Adding a model file by hand would not change that.",
            // K10 to K12, the pre-scan gate.
            "Scan without a detection model?",
            "This scan will not look for people's names or company names, and it matches an address only in the Chinese street form, stopping at the street number. Those values stay in the document and are not in the review list. Emails, phones, dates, amounts, ID numbers, case numbers, bank accounts, license plates, WeChat IDs, links, and seals are still found.",
            "Scan Without Names",
            // K13 to K16, the four advisory branches.
            "No detection model is installed, so this scan will not look for people's names or company names, and it matches an address only in the Chinese street form. It still finds emails, phones, dates, amounts, ID numbers, and case numbers. Add a model to find names.",
            "The model for the detection level you chose is not installed, so this scan will not look for people's names or company names, and it matches an address only in the Chinese street form. It still finds emails, phones, dates, amounts, ID numbers, and case numbers. Add that model, or choose an installed level in Settings.",
            "Patterns only is selected and no detection model is installed, so no scan on this Mac looks for people's names or company names. Those names stay in the document. Add a model, then choose a detection level in Settings.",
            "This Mac does not have the memory to run a detection model, so scans here match patterns only. People's names and company names stay in the document.",
            // K17 to K19, the banner, the tooltip and onboarding step 1.
            "Document ready. Click Scan for PII to spot dates, amounts, emails, phones, and ID numbers. Names and company names need a detection model.",
            "Spot PII in the open document: dates, amounts, emails, phones, ID numbers (Cmd+Shift+S). People's names and company names need a detection model.",
            "Drop Word, PDF, or text files (or a .zip). The app scans each one and you review what it will protect. Which kinds of value it can find depends on the detection model above.",
            // K20 to K22, the export gate.
            "Export a copy where the AI pass did not run?",
            "The AI pass did not run on at least one of these documents, so people's names and company names were not looked for there and are still in the copy you are about to write. Read that copy before you hand it to an AI tool, or add a detection model and scan those documents again.",
            "Export Anyway",
            // K24 and K25, the export gate's partial-coverage body.
            "Export a copy where the AI pass did not finish?",
            "The AI pass started on at least one of these documents and did not cover all of it, so some people's names and company names were found there and others were not. A review list can look complete and still be short of what the text holds. Read the copy you are about to write before you hand it to an AI tool, or scan those documents again.",
            // K23, the post-scan failure sentence.
            "No detection model is installed for the selected detection level, so people's names and company names were not looked for, and an address was matched only in the Chinese street form. Choose a different level in Settings, or add the model file."
        ]
        XCTAssertEqual(
            keys.count, 24,
            "23 from the specification, plus the two that separate a partial AI "
                + "pass from one that never ran, less one: the old three-paragraph "
                + "ask body collapsed to one sentence plus the defer row's evidence"
        )

        for language in [AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese] {
            for key in keys {
                let value = L10n.string(key, language: language)
                XCTAssertFalse(value.isEmpty, "\(language) has an empty value for: \(key)")
                if language != .english {
                    XCTAssertNotEqual(
                        value, key,
                        "\(language) is missing a translation for: \(key)"
                    )
                }
            }
        }
    }

    // MARK: - A partial AI pass is not a pass that never ran

    func testTheExportGateTellsAPartialPassApartFromOneThatNeverRan() {
        typealias Document = (
            canExport: Bool, aiRan: Bool, aiFailure: String?, aiRanPartially: Bool
        )

        let neverRan: [Document] = [
            (canExport: true, aiRan: false, aiFailure: "no model", aiRanPartially: false)
        ]
        let partial: [Document] = [
            (
                canExport: true, aiRan: false,
                aiFailure: "AI could not fully scan 2 segments", aiRanPartially: true
            )
        ]

        XCTAssertNil(ModelSetupPresentation.exportGateReason(documents: []))
        XCTAssertEqual(
            ModelSetupPresentation.exportGateReason(documents: neverRan), .didNotRun
        )
        XCTAssertEqual(
            ModelSetupPresentation.exportGateReason(documents: partial), .ranPartially
        )

        // A mixed tray takes the partial body. A populated review list that is
        // short of the text reads as a finished job, which is the more
        // dangerous of the two to describe loosely.
        XCTAssertEqual(
            ModelSetupPresentation.exportGateReason(documents: neverRan + partial),
            .ranPartially
        )

        // The partial term is not a way past the other two conditions.
        XCTAssertNil(
            ModelSetupPresentation.exportGateReason(documents: [
                (
                    canExport: false, aiRan: false,
                    aiFailure: "AI could not fully scan 2 segments", aiRanPartially: true
                )
            ]),
            "a document that cannot be exported carries nothing into the handoff"
        )
        XCTAssertNil(
            ModelSetupPresentation.exportGateReason(documents: [
                (canExport: true, aiRan: false, aiFailure: nil, aiRanPartially: true)
            ]),
            "no failure means the pass was never asked for"
        )

        let didNotRun = ModelSetupPresentation
            .exportConfirmation(reason: .didNotRun, language: .english)
        let ranPartially = ModelSetupPresentation
            .exportConfirmation(reason: .ranPartially, language: .english)

        XCTAssertNotEqual(
            didNotRun.title, ranPartially.title,
            "a pass that covered part of the document is not one that never ran"
        )
        XCTAssertNotEqual(
            didNotRun.message, ranPartially.message,
            "saying the pass did not run when it ran and stopped short "
                + "understates it: the review list looks populated and is "
                + "incomplete"
        )
        XCTAssertEqual(
            didNotRun.proceed, ranPartially.proceed,
            "the action is the same either way"
        )
        XCTAssertTrue(
            ranPartially.message.contains("some people's names and company names were found there and others were not"),
            "the partial body must say what partial coverage means"
        )
        XCTAssertFalse(
            ranPartially.message.contains("did not run"),
            "the pass did run; that is the whole distinction"
        )
    }

    func testNeitherExportBodySoftensIntoAClaimThatEverythingWasFound() {
        for reason in [
            ModelSetupPresentation.ExportGateReason.didNotRun, .ranPartially
        ] {
            for language in [
                AppLanguage.english, .french, .simplifiedChinese, .traditionalChinese
            ] {
                let copy = ModelSetupPresentation
                    .exportConfirmation(reason: reason, language: language)
                for text in [copy.title, copy.message, copy.proceed] {
                    XCTAssertFalse(
                        text.isEmpty, "\(language) has empty export copy for \(reason)"
                    )
                    XCTAssertFalse(
                        text.contains("\u{2014}") || text.contains("\u{2013}"),
                        "\(language) uses a prohibited dash in the export copy"
                    )
                }
                let lowered = copy.message.lowercased()
                for claim in [
                    "guaranteed", "100%", "all sensitive", "everything",
                    "accuracy decreases", "accuracy"
                ] {
                    XCTAssertFalse(
                        lowered.contains(claim),
                        "\(language) export copy for \(reason) must not claim \(claim)"
                    )
                }
            }

            // The house framing: enumerate what was and was not looked for,
            // and never suggest the review list is the whole of it.
            let english = ModelSetupPresentation
                .exportConfirmation(reason: reason, language: .english).message
            XCTAssertTrue(
                english.contains("people's names and company names"),
                "\(reason) must name what is at stake"
            )
            XCTAssertTrue(
                english.contains("before you hand it to an AI tool"),
                "\(reason) must state the one thing the reader can still do"
            )
        }
    }
}
