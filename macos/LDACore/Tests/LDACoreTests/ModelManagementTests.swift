//
//  ModelManagementTests.swift
//  LDACoreTests
//
//  Download eligibility and the shared demotion rule.
//
//  Two behaviours here are easy to get subtly wrong and expensive when wrong:
//  offering a download the machine can never use, and demoting a user UPWARD
//  into a setting they did not choose after they remove something.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

final class ModelManagementTests: XCTestCase {

    private let catalog = ModelCatalog.load()

    // MARK: - canDownload

    func testABundledModelIsNeverOfferedAsADownload() {
        let quick = catalog.tier(for: .quick)!
        if ModelCatalog.isBundled(quick) {
            XCTAssertFalse(AISettings.canDownload(quick, installedGB: 64),
                           "Quick ships in the app; downloading it again wastes 2.74 GB")
        }
    }

    func testAModelTheMacCannotRunIsNotOfferedAtAnyEntryPoint() {
        // Soldered memory means this never becomes true later, so the file
        // would be inert forever.
        for level in [DetectionLevel.balanced, .mostThorough] {
            XCTAssertFalse(
                AISettings.canDownload(catalog.tier(for: level)!, installedGB: 16),
                "\(level.rawValue) must not be downloadable on a 16 GB Mac"
            )
        }
    }

    func testTheSameModelsAreOfferedOnAMacWithTheMemory() {
        // The rule above must not pass by refusing everything.
        for level in [DetectionLevel.balanced, .mostThorough] {
            XCTAssertTrue(
                AISettings.canDownload(catalog.tier(for: level)!, installedGB: 32),
                "\(level.rawValue) should be downloadable on a 32 GB Mac"
            )
        }
    }

    func testAnEighteenGigMacIsOfferedNeitherLargeModel() {
        // 18 GB is a shipping configuration and the one the bracketed budget
        // used to get wrong.
        for level in [DetectionLevel.balanced, .mostThorough] {
            XCTAssertFalse(AISettings.canDownload(catalog.tier(for: level)!, installedGB: 18))
        }
    }

    // MARK: - bestAvailableLevel

    func testFallsBackToPatternsOnlyWhenNothingIsRunnable() {
        // On an 8 GB Mac the budget clears nothing, so the honest destination
        // is Patterns only rather than a rung that cannot run.
        XCTAssertEqual(
            AISettings.bestAvailableLevel(catalog: catalog, installedGB: 8),
            .patternsOnly
        )
    }

    func testASixteenGigMacFallsBackToQuick() {
        // Quick is bundled, so it is available without any download.
        let level = AISettings.bestAvailableLevel(catalog: catalog, installedGB: 16)
        if ModelCatalog.isBundled(catalog.tier(for: .quick)!) {
            XCTAssertEqual(level, .quick)
        } else {
            XCTAssertEqual(level, .patternsOnly)
        }
    }

    func testDemotionNeverPromotesPastTheRemovedLevel() {
        // The notAbove bound. Removing Balanced while Most thorough happens to
        // be installed must land on Quick, never on Most thorough: the user
        // chose Balanced, and silently upgrading them changes how long every
        // scan takes without asking.
        let level = AISettings.bestAvailableLevel(
            catalog: catalog, installedGB: 32, notAbove: .balanced
        )
        XCTAssertNotEqual(level, .mostThorough, "must not promote above the removed rung")
        XCTAssertNotEqual(level, .balanced, "must not stay on the rung being removed")
    }

    func testDemotionFromQuickHasNowhereToGoButPatternsOnly() {
        let level = AISettings.bestAvailableLevel(
            catalog: catalog, installedGB: 32, notAbove: .quick
        )
        XCTAssertEqual(level, .patternsOnly)
    }

    func testLaunchFallbackIsUnboundedAndPicksTheBestRunnableRung() {
        // nil notAbove is the launch and recovery case: any available rung is
        // fine because the user is not removing anything.
        let level = AISettings.bestAvailableLevel(catalog: catalog, installedGB: 64)
        XCTAssertTrue(level == .quick || level == .patternsOnly,
                      "with only Quick present the best runnable rung is Quick, got \(level)")
    }

    func testAnEmptyCatalogDegradesToPatternsOnlyRatherThanCrashing() {
        XCTAssertEqual(
            AISettings.bestAvailableLevel(catalog: ModelCatalog(tiers: []), installedGB: 64),
            .patternsOnly
        )
    }

    // MARK: - notAbove must fail closed

    func testNotAbovePatternsOnlyYieldsPatternsOnly() {
        // Regression: order.firstIndex(of: .patternsOnly) is nil, so the ceiling
        // silently vanished and the bound failed OPEN, returning the HIGHEST
        // rung. In a shared gate used by launch, recovery and removal, an
        // unknown bound must never mean "no bound".
        XCTAssertEqual(
            AISettings.bestAvailableLevel(catalog: catalog, installedGB: 64,
                                          notAbove: .patternsOnly),
            .patternsOnly
        )
    }

    func testNotAboveIsHonouredForEveryModelRung() {
        for bound in DetectionLevel.modelLevels {
            let result = AISettings.bestAvailableLevel(
                catalog: catalog, installedGB: 64, notAbove: bound
            )
            XCTAssertNotEqual(result, bound, "must not stay on the removed rung")
            if let bi = DetectionLevel.modelLevels.firstIndex(of: bound),
               let ri = DetectionLevel.modelLevels.firstIndex(of: result) {
                XCTAssertLessThan(ri, bi, "must demote, never promote")
            }
        }
    }

    // MARK: - Offline mode

    private func offlineDefaults(_ on: Bool) -> UserDefaults {
        let suite = TestNamespace.suiteName("model-offline")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        d.set(on, forKey: AISettings.offlineModeKey)
        return d
    }

    func testOfflineModeIsOffByDefault() {
        let suite = TestNamespace.suiteName("model-offline")
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        XCTAssertFalse(AISettings.isOfflineMode(defaults: d))
    }

    func testOfflineModeBlocksEveryDownloadRegardlessOfMemory() {
        // Checked at the bottom of the stack, so a UI path cannot bypass it.
        let d = offlineDefaults(true)
        for level in DetectionLevel.modelLevels {
            XCTAssertFalse(
                AISettings.canDownload(catalog.tier(for: level)!,
                                       installedGB: 64, defaults: d),
                "\(level.rawValue) must not be downloadable in offline mode"
            )
        }
    }

    func testTurningOfflineModeOffRestoresDownloads() {
        // The rule above must not pass by refusing everything permanently.
        let d = offlineDefaults(false)
        XCTAssertTrue(AISettings.canDownload(catalog.tier(for: .balanced)!,
                                             installedGB: 64, defaults: d))
    }

    func testAnUnmanagedInstallReportsNoForcedValue() {
        XCTAssertNil(AISettings.managedOfflineMode(defaults: offlineDefaults(true)),
                     "a plain user preference is not a managed one")
    }

    // MARK: - Redundant container copy

    func testABundledTierWithNoContainerCopyHasNothingToReclaim() {
        let quick = catalog.tier(for: .quick)!
        XCTAssertNil(ModelCatalog.redundantContainerCopy(for: quick),
                     "no container copy exists in the test environment")
    }

    func testANonBundledTierIsNeverReportedAsRedundant() {
        // Balanced is downloaded, so a container copy is the ONLY copy and
        // deleting it as "redundant" would remove the model entirely.
        for level in [DetectionLevel.balanced, .mostThorough] {
            XCTAssertNil(ModelCatalog.redundantContainerCopy(for: catalog.tier(for: level)!),
                         "\(level.rawValue) is not bundled, so its copy is not redundant")
        }
    }

    // MARK: - Annotation inputs

    func testEveryTierCarriesTheFiguresTheAnnotationNeeds() {
        // The sheet states download size, memory, time, and the RAM
        // requirement for each model. A zero renders as a confident lie.
        for level in DetectionLevel.modelLevels {
            let t = catalog.tier(for: level)!
            XCTAssertGreaterThan(t.sizeBytes, 0, "\(t.id) size")
            XCTAssertGreaterThan(t.peakRSSGB, 0, "\(t.id) memory")
            XCTAssertGreaterThan(t.secondsPerDocument, 0, "\(t.id) time")
            XCTAssertFalse(MemoryGate.requirementText(for: t, installedGB: 16).isEmpty)
        }
    }
}
