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

    // MARK: - One chokepoint, and the stale model path it fixes

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

    func testEveryScanEntryPointOnlyBumpsATokenSoOneGateCoversThemAll() throws {
        // The gate can only be bypassed by an entry point nobody rerouted, so
        // the banner's three buttons must not dispatch a pass themselves.
        let banner = try uiSource("AppShellStatusBanner.swift")
        XCTAssertFalse(
            banner.contains("await model.anonymize()"),
            "Scan for PII and Re-scan must go through the shell's gate"
        )
        XCTAssertFalse(
            banner.contains("await session.anonymizeAll()"),
            "Scan All must go through the shell's gate too: it was the second, "
                + "ungated entry point"
        )
        XCTAssertTrue(banner.contains("model.requestAnonymize()"))
        XCTAssertTrue(banner.contains("session.requestScanAll()"))

        let shell = try uiSource("AppShell.swift")
        for token in [
            "model.anonymizeRequestToken",
            "session.scanAllRequestToken",
            "session.exportForAIRequestToken"
        ] {
            XCTAssertTrue(shell.contains(token), "\(token) must reach the shell")
        }
        XCTAssertTrue(shell.contains("handleScanRequest(.active)"))
        XCTAssertTrue(shell.contains("handleScanRequest(.all)"))
    }

    func testADismissalOnlyRecordsAnAnswerWhereTheAskWasOnScreen() throws {
        // The fallback in onboarding's onDismiss exists so that an escape,
        // should a future edit drop .interactiveDismissDisabled, is recorded
        // rather than forgotten. It must not record for a Mac that has a
        // model, because that sheet opens straight onto the three steps: an
        // answer inferred there would silence the ask for that user if they
        // ever removed the model.
        let shell = try uiSource("AppShell.swift")
        XCTAssertTrue(
            shell.contains(
                "if !hasDetectionModel, AISettings.modelSetupAnswer() == nil {"
            ),
            "the dismissal fallback must be scoped to the state where the ask "
                + "was actually presented"
        )
        XCTAssertTrue(
            shell.contains(
                "AISettings.recordModelSetupAnswer(canRunAModel ? .declined : .unavailable)"
            ),
            "a Mac that can run nothing was never asked a question it could "
                + "answer, so its fallback is unavailable rather than declined"
        )
    }

    func testTheScanChokepointReresolvesTheModelPathBeforeDispatching() throws {
        // Defect D1. ReviewModel captures modelPath at model creation, and a
        // completed install changes neither customModelPath nor
        // detectionLevelRaw, so LDAApp's two reapply triggers do not fire: the
        // advisory cleared the instant the download landed while an
        // already-open document kept scanning with no model.
        let shell = try uiSource("AppShell.swift")
        guard let start = shell.range(of: "private func runScan("),
              let end = shell.range(
                of: "private func requestExportForAI(",
                range: start.upperBound..<shell.endIndex
              ) else {
            XCTFail("runScan is missing")
            return
        }
        let body = shell[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(
            body.contains("session.reapplyConfiguration()"),
            "the one place every scan is dispatched must re-resolve the model "
                + "path first"
        )
        let reapply = try XCTUnwrap(body.range(of: "session.reapplyConfiguration()"))
        let dispatch = try XCTUnwrap(body.range(of: "await model.anonymize()"))
        XCTAssertTrue(
            reapply.upperBound < dispatch.lowerBound,
            "re-resolving after dispatch would be too late"
        )
        // The rejected alternative. Matched as the observation rather than as
        // the word, because the comment above runScan names it on purpose.
        XCTAssertFalse(
            shell.contains("onChange(of: installer.phases"),
            "observing phases republishes on every progress tick and says "
                + "nothing about a file that arrived by another route"
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

    // MARK: - A scan request carries the document that triggered it

    func testAScanRequestCarriesItsTargetsSoADocumentSwitchCannotRedirectIt() {
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(PendingScan.active(first).targets, [first])
        XCTAssertEqual(PendingScan.all([first, second]).targets, [first, second])
        XCTAssertNotEqual(
            PendingScan.active(first), PendingScan.active(second),
            "two requests for different documents must not compare equal: the "
                + "identity is part of the request, not a decoration over it"
        )
    }

    func testTheShellResolvesAScanTargetOnceWhenTheUserAsks() throws {
        let shell = try uiSource("AppShell.swift")
        XCTAssertFalse(
            shell.contains("scanTargets(for:"),
            "deriving the target twice, once when the gate fires and once "
                + "inside the confirm closure, let a document switch redirect "
                + "the acknowledgment and the dispatch to a document that never "
                + "triggered the ask"
        )
        XCTAssertEqual(
            shell.components(separatedBy: "session.activeEntryID").count - 1, 1,
            "the active document is read in exactly one place: the resolver "
                + "that builds the request"
        )

        guard let start = shell.range(of: "private func runScan("),
              let end = shell.range(
                of: "private func requestExportForAI(",
                range: start.upperBound..<shell.endIndex
              ) else {
            XCTFail("runScan is missing")
            return
        }
        let body = shell[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(
            body.contains("$0.id == id"),
            "the dispatch must follow the document the request names"
        )
        XCTAssertFalse(
            body.contains("activeEntryID"),
            "re-reading the selection at dispatch time is the timing "
                + "dependency this snapshot removes"
        )
        XCTAssertTrue(
            body.contains("session.reapplyConfiguration()"),
            "D1 must not regress: the one dispatch point still re-resolves the "
                + "model path first"
        )
    }

    // MARK: - Every route to Manage Models records the answer

    func testEveryRouteIntoManageModelsRecordsTheAnswer() throws {
        // A stored "declined" must not survive the user visibly acting to fix
        // it. Two of these routes used to leave the answer alone.
        let shell = try uiSource("AppShell.swift")
        guard let start = shell.range(of: "private func missingModelAdvisory") else {
            XCTFail("missingModelAdvisory is missing")
            return
        }
        XCTAssertTrue(
            shell[start.lowerBound...].prefix(1_200)
                .contains("AISettings.recordModelSetupAnswer(.accepted)"),
            "the persistent advisory's button is the route a decliner takes "
                + "back, so it must record that they took it"
        )

        // Onboarding funnels every route through one helper, so a button added
        // later cannot forget.
        let onboarding = try uiSource("OnboardingView.swift")
        XCTAssertEqual(
            onboarding.components(separatedBy: "onOpenModelManagement()").count - 1, 1,
            "every onboarding route into Manage Models must go through the one "
                + "helper that records the answer"
        )
        guard let helper = onboarding.range(of: "private func openModelManagement()") else {
            XCTFail("the recording helper is missing")
            return
        }
        XCTAssertTrue(
            onboarding[helper.lowerBound...].prefix(400)
                .contains("AISettings.recordModelSetupAnswer(.accepted)")
        )

        // Both gate dialogs record on their fix button too.
        let flow = try uiSource("ModelSetupFlow.swift")
        XCTAssertEqual(
            flow.components(
                separatedBy: "AISettings.recordModelSetupAnswer(.accepted)"
            ).count - 1,
            2,
            "the pre-scan gate and the export gate each carry a fix button"
        )
    }

    func testRecordingAnAnswerOnThoseRoutesNeverSilencesTheGate() {
        let (defaults, name) = makeDefaults("fix-route")
        defer { defaults.removePersistentDomain(forName: name) }

        // Every Manage Models route records .accepted. If the gate were keyed
        // on the answer, pressing Set Up a Model and then closing the sheet
        // without installing anything would buy permanent silence.
        AISettings.recordModelSetupAnswer(.accepted, defaults: defaults)
        XCTAssertTrue(
            AISettings.scanNeedsModelConfirmation(
                catalog: ladder, installedGB: 16.0, defaults: defaults
            ),
            "the gate reads the machine, so acting on the fix without finishing "
                + "it must still ask"
        )
        XCTAssertNil(
            defaults.string(forKey: AISettings.detectionLevelKey),
            "recording an answer must never write a detection level"
        )
    }

    // MARK: - The export gate routes on state, not on prose

    func testTheExportGateReadsAStateFlagRatherThanTheWarningText() throws {
        // The two cases are not separable from what ReviewModel used to
        // expose: aiActive is false for a pass that never ran AND for one that
        // stopped short, and the two warnings differ only by localized prose.
        // So the truth is carried out of the pass as state. Recovering it by
        // matching another string's words would work in English and nowhere
        // else.
        let detection = try uiSource("ReviewModelDetection.swift")
        XCTAssertTrue(
            detection.contains("aiRanPartially: llm.partial"),
            "the detection pass must report partial coverage as a fact"
        )
        let review = try uiSource("ReviewModel.swift")
        XCTAssertTrue(
            review.contains("aiRanPartially = outcome.aiRanPartially"),
            "the window must publish it"
        )
        let shell = try uiSource("AppShell.swift")
        XCTAssertTrue(
            shell.contains("$0.model.aiRanPartially"),
            "the shell must pass it into the gate"
        )
        let flow = try uiSource("ModelSetupFlow.swift")
        XCTAssertFalse(
            flow.contains("aiWarning"),
            "the dialog must not read the other string's words to choose which "
                + "sentence to show"
        )
    }
}
