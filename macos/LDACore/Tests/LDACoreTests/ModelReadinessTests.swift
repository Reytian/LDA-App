import XCTest
@testable import LDAUI

final class ModelReadinessTests: XCTestCase {
    func testSelectingAMissingModelNeverPromisesReadiness() {
        for phase: ModelInstallPhase in [.waiting, .cancelled, .installed, .failed(.digestMismatch)] {
            XCTAssertEqual(ModelReadiness.statusKey(
                selected: true, installed: false, availability: .available, phase: phase
            ), "Not installed")
        }
    }

    func testReadyRequiresSelectionInstallationAndSupportedHardware() {
        XCTAssertEqual(ModelReadiness.statusKey(
            selected: true, installed: true, availability: .available, phase: .installed
        ), "Ready to scan")
        XCTAssertEqual(ModelReadiness.statusKey(
            selected: true, installed: true, availability: .tight, phase: .installed
        ), "Ready to scan")
        XCTAssertEqual(ModelReadiness.statusKey(
            selected: false, installed: true, availability: .available, phase: .installed
        ), "Installed")
        XCTAssertEqual(ModelReadiness.statusKey(
            selected: true, installed: true,
            availability: .insufficientMemory(needsGB: 12, budgetGB: 6), phase: .installed
        ), "Installed, cannot run on this Mac")
    }

    func testAnIncompleteDownloadDoesNotShowReady() {
        XCTAssertEqual(ModelReadiness.statusKey(
            selected: true, installed: true, availability: .available,
            phase: .downloading(fraction: 0.5, received: 5, expected: 10)
        ), "Downloading")
        XCTAssertEqual(ModelReadiness.statusKey(
            selected: true, installed: true, availability: .available, phase: .verifying
        ), "Verifying")
    }

    func testNewGuidanceAndStatusesAreTranslated() {
        let keys = [
            "Selected", "Installed", "Not installed", "Ready to scan",
            "Installed, cannot run on this Mac", "Downloading", "Verifying",
            "Memory and test results", "%@ is recommended for this Mac.", "%@ on disk"
        ]
        for language: AppLanguage in [.french, .simplifiedChinese, .traditionalChinese] {
            for key in keys {
                XCTAssertNotEqual(L10n.string(key, language: language), key)
            }
            for level in DetectionLevel.modelLevels {
                XCTAssertNotEqual(
                    ModelAnnotation.summary(for: level, language: language),
                    ModelAnnotation.summary(for: level, language: .english)
                )
            }
        }
    }
}
