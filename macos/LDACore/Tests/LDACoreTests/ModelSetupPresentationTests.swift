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
        let body = ModelSetupPresentation
            .askBody(route: .download, language: .english)
            .joined(separator: " ")

        for clause in [
            "people's names and company names",
            "not detected",
            "not in the review list",
            "still identifies your client",
            "Chinese street form"
        ] {
            XCTAssertTrue(
                body.contains(clause),
                "the ask must state: \(clause)"
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
        copy.append(ModelSetupPresentation.exportConfirmation(language: .english).message)

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
            "First, add a detection model"
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
        typealias Document = (canExport: Bool, aiRan: Bool, aiFailure: String?)

        XCTAssertFalse(
            ModelSetupPresentation.exportNeedsConfirmation(documents: []),
            "nothing to export, nothing to warn about"
        )
        XCTAssertFalse(
            ModelSetupPresentation.exportNeedsConfirmation(
                documents: [(canExport: false, aiRan: false, aiFailure: "no model")]
            ),
            "a document that cannot be exported carries nothing into the handoff"
        )
        XCTAssertFalse(
            ModelSetupPresentation.exportNeedsConfirmation(
                documents: [(canExport: true, aiRan: true, aiFailure: nil)]
            ),
            "the pass ran"
        )
        XCTAssertFalse(
            ModelSetupPresentation.exportNeedsConfirmation(
                documents: [(canExport: true, aiRan: false, aiFailure: nil)]
            ),
            "a deliberate patterns-only run is a choice, not a failure"
        )
        XCTAssertTrue(
            ModelSetupPresentation.exportNeedsConfirmation(
                documents: [(canExport: true, aiRan: false, aiFailure: "no model")]
            ),
            "asked for and did not run: this is the disclosure case"
        )
        // One bad document in a tray of good ones still asks.
        let mixed: [Document] = [
            (canExport: true, aiRan: true, aiFailure: nil),
            (canExport: true, aiRan: false, aiFailure: "no model"),
            (canExport: true, aiRan: true, aiFailure: nil)
        ]
        XCTAssertTrue(ModelSetupPresentation.exportNeedsConfirmation(documents: mixed))
    }

    // MARK: - Every new string reaches all four catalogs

    func testEveryNewSetupStringIsTranslatedInAllFourCatalogs() {
        let keys = [
            // K1 to K3, the ask body.
            "A detection model is what finds people's names and company names. Without one, a scan matches patterns only: emails, phones, dates, amounts, ID numbers, Unified Social Credit Codes, bank accounts, case numbers, license plates, WeChat IDs, links, and seals.",
            "Names and company names are not detected, so they stay in the document, they are not in the review list, and the copy you hand to an AI tool still identifies your client. An address is matched only in the Chinese street form, and the match stops at the street number.",
            "In our own test on two agreements, a scan with no model left 32 of the 36 names, companies, and addresses in place, and matched the other 4 only in part.",
            // K4 to K7, the two routes and the download progress line.
            "Download the Model (%@)",
            "I Already Have the File\u{2026}",
            "Downloading the detection model. You can read the next steps while it arrives.",
            "The detection model is installed. A scan will look for names, companies, and addresses.",
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
            // K23, the post-scan failure sentence.
            "No detection model is installed for the selected detection level, so people's names and company names were not looked for, and an address was matched only in the Chinese street form. Choose a different level in Settings, or add the model file."
        ]
        XCTAssertEqual(keys.count, 23, "the specification lists 23 keys")

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
}
