//
//  ModelSetupGateTests.swift
//  LDACoreTests
//
//  The three predicates behind the first-run model ask and the pre-scan gate,
//  plus the one preference key that records the answer.
//
//  The property these tests exist to protect: the gate is keyed on MACHINE
//  STATE (no model present and a model could run), never on the stored answer.
//  Keying it on the answer would let a single "Not Now" turn into permanent
//  silence about the fact that a scan does not look for names, which is the
//  failure this whole flow exists to prevent.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

final class ModelSetupGateTests: XCTestCase {

    /// A defaults domain per test so cases cannot leak into one another.
    private func makeDefaults(_ label: String) -> (UserDefaults, String) {
        TestNamespace.defaults("model-setup-\(label)")
    }

    /// Same shape as ModelTiersTests' helper, so a synthetic catalog here
    /// describes a tier the memory gate can reason about.
    private func tier(
        id: String,
        level: String,
        peak: Double,
        file: String = "m.gguf"
    ) -> ModelTier {
        ModelTier(
            id: id, level: level, displayName: id, fileName: file,
            sizeBytes: 1_000, sha256: "", peakRSSGB: peak, secondsPerDocument: 10,
            architecture: "qwen35", blockCount: 32, embeddingLength: 2560,
            sourceURL: "https://example.invalid/m.gguf"
        )
    }

    /// The shipped ladder's peaks, so the boundary assertions below are the
    /// real boundary rather than a fixture's.
    private var ladder: ModelCatalog {
        ModelCatalog(tiers: [
            tier(id: "quick", level: "quick", peak: 3.6),
            tier(id: "balanced", level: "balanced", peak: 9.8),
            tier(id: "most-thorough", level: "mostThorough", peak: 13.83)
        ])
    }

    // MARK: - The gate reads the machine, not the rung

    func testScanNeedsConfirmationOnlyWhenThisMacHasNoModelAndCouldRunOne() {
        let (defaults, name) = makeDefaults("scan-gate")
        defer { defaults.removePersistentDomain(forName: name) }

        // No model file anywhere, and this Mac could run Quick.
        XCTAssertTrue(
            AISettings.scanNeedsModelConfirmation(
                catalog: ladder, installedGB: 16.0, defaults: defaults
            )
        )
        // The same machine state on a Mac that cannot run any tier: nothing to
        // ask, because there is no remedy to offer.
        XCTAssertFalse(
            AISettings.scanNeedsModelConfirmation(
                catalog: ladder, installedGB: 12.0, defaults: defaults
            )
        )
        XCTAssertFalse(
            AISettings.scanNeedsModelConfirmation(
                catalog: ladder, installedGB: 8.0, defaults: defaults
            )
        )
        // An empty catalog offers no tier at all.
        XCTAssertFalse(
            AISettings.scanNeedsModelConfirmation(
                catalog: ModelCatalog(tiers: []), installedGB: 32.0, defaults: defaults
            )
        )

        // The predicate must be independent of the selected rung: a deliberate
        // patterns-only user with no file is exactly the person who otherwise
        // never learns that names are not looked for.
        for level in DetectionLevel.allCases {
            AISettings.setDetectionLevel(level, defaults: defaults)
            XCTAssertTrue(
                AISettings.scanNeedsModelConfirmation(
                    catalog: ladder, installedGB: 16.0, defaults: defaults
                ),
                "\(level.rawValue) must not change a machine-keyed predicate"
            )
        }

        // A resolvable custom model is a model on this Mac, for every rung.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(TestNamespace.prefix)-gate-model.gguf")
        _ = FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        AISettings.setCustomModel(url: file, defaults: defaults)
        for level in DetectionLevel.allCases {
            AISettings.setDetectionLevel(level, defaults: defaults)
            XCTAssertFalse(
                AISettings.scanNeedsModelConfirmation(
                    catalog: ladder, installedGB: 16.0, defaults: defaults
                ),
                "\(level.rawValue): a model IS present, so nothing to confirm"
            )
        }
        AISettings.setCustomModel(url: nil, defaults: defaults)
    }

    func testCanRunAnyModelBoundaryIsTwelveToSixteenGigabytes() {
        // MemoryGate.budgetGB clears Quick's 3.6 GB peak only at about
        // 12.43 GB installed, so 12 GB is out and 16 GB is in. Apple silicon
        // memory is soldered, which is why a false here is permanent.
        for installed in [8.0, 12.0] {
            XCTAssertFalse(
                AISettings.canRunAnyModel(catalog: ladder, installedGB: installed),
                "\(installed) GB cannot run the smallest tier"
            )
        }
        for installed in [16.0, 24.0, 32.0] {
            XCTAssertTrue(
                AISettings.canRunAnyModel(catalog: ladder, installedGB: installed),
                "\(installed) GB can run at least Quick"
            )
        }
    }

    // MARK: - The recorded answer

    func testDeclinedIsRecordedAndSurvivesRelaunchWithoutSilencingTheGate() {
        let (defaults, name) = makeDefaults("answer")
        defer { defaults.removePersistentDomain(forName: name) }

        XCTAssertNil(
            AISettings.modelSetupAnswer(defaults: defaults),
            "absent means never asked"
        )

        AISettings.recordModelSetupAnswer(.declined, defaults: defaults)
        XCTAssertEqual(AISettings.modelSetupAnswer(defaults: defaults), .declined)

        // The sheet honours the decline forever: no nag at launch.
        XCTAssertFalse(
            AISettings.shouldPresentModelAsk(
                catalog: ladder, installedGB: 16.0, defaults: defaults
            ),
            "a decline must not bring the ask back at every launch"
        )
        // The gate does NOT. A decline is an answer about the sheet, not
        // consent to a silent scan.
        XCTAssertTrue(
            AISettings.scanNeedsModelConfirmation(
                catalog: ladder, installedGB: 16.0, defaults: defaults
            ),
            "a decline must never decay into permanent silence"
        )
    }

    func testAcceptedIsNotTerminalWhileNoModelArrived() {
        let (defaults, name) = makeDefaults("accepted")
        defer { defaults.removePersistentDomain(forName: name) }

        AISettings.recordModelSetupAnswer(.accepted, defaults: defaults)
        XCTAssertTrue(
            AISettings.shouldPresentModelAsk(
                catalog: ladder, installedGB: 16.0, defaults: defaults
            ),
            "pressed Download and cancelled, or left the drive at the office: "
                + "the ask is unresolved, so it returns once more"
        )

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(TestNamespace.prefix)-accepted-model.gguf")
        _ = FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: file) }
        AISettings.setCustomModel(url: file, defaults: defaults)
        XCTAssertFalse(
            AISettings.shouldPresentModelAsk(
                catalog: ladder, installedGB: 16.0, defaults: defaults
            ),
            "the file arrived, so there is nothing left to ask"
        )
        AISettings.setCustomModel(url: nil, defaults: defaults)
    }

    func testUnavailableIsRecordedOnlyWhereNoTierCanRun() {
        let (defaults, name) = makeDefaults("unavailable")
        defer { defaults.removePersistentDomain(forName: name) }

        AISettings.recordModelSetupAnswer(.unavailable, defaults: defaults)
        XCTAssertEqual(AISettings.modelSetupAnswer(defaults: defaults), .unavailable)
        XCTAssertFalse(
            AISettings.shouldPresentModelAsk(
                catalog: ladder, installedGB: 8.0, defaults: defaults
            )
        )
        XCTAssertFalse(
            AISettings.scanNeedsModelConfirmation(
                catalog: ladder, installedGB: 8.0, defaults: defaults
            ),
            "this Mac must never be shown a dialog it cannot resolve"
        )
    }

    func testTheAnswerKeyDoesNotTouchTheDetectionLevel() {
        // Recording a decline as detectionLevel = .patternsOnly would set
        // usesLLM == false, and isModelMissing() short-circuits on usesLLM, so
        // the red advisory would go quiet for the one user who most needs it.
        for answer in [
            AISettings.ModelSetupAnswer.accepted, .declined, .unavailable
        ] {
            let (defaults, name) = makeDefaults("level-\(answer.rawValue)")
            defer { defaults.removePersistentDomain(forName: name) }

            AISettings.recordModelSetupAnswer(answer, defaults: defaults)
            XCTAssertNil(
                defaults.string(forKey: AISettings.detectionLevelKey),
                "\(answer.rawValue) must not write a detection level"
            )
            XCTAssertEqual(
                AISettings.detectionLevel(defaults: defaults, catalog: ladder),
                .quick,
                "the rung that reports its own failure must stay selected"
            )
        }
    }
}
