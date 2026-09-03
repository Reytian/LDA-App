//
//  MemoryGateTests.swift
//  LDACoreTests
//
//  MemoryGate.requirementText / localizedRequirementText: the sentence a
//  disabled rung shows must name a size that actually runs it, not merely a
//  size whose budget it clears. Before the fix, Balanced and Most thorough
//  both reported "Needs 24 GB", one of the two figures false.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

final class MemoryGateTests: XCTestCase {

    func testRequirementTextNamesASizeThatActuallyRuns() {
        let catalog = ModelCatalog.load()
        let balanced = try? XCTUnwrap(catalog.tier(for: .balanced))
        let mostThorough = try? XCTUnwrap(catalog.tier(for: .mostThorough))
        guard let balanced, let mostThorough else {
            return XCTFail("the shipped catalog must carry Balanced and Most thorough")
        }

        let balancedText = MemoryGate.requirementText(for: balanced, installedGB: 16)
        let mostThoroughText = MemoryGate.requirementText(for: mostThorough, installedGB: 16)

        XCTAssertTrue(balancedText.contains("24 GB"), balancedText)
        XCTAssertTrue(mostThoroughText.contains("32 GB"), mostThoroughText)
        XCTAssertNotEqual(
            balancedText, mostThoroughText,
            "two rungs with different real requirements must not report the same figure"
        )
    }

    func testLocalizedRequirementTextAgreesWithTheUnlocalizedForm() {
        let catalog = ModelCatalog.load()
        guard let mostThorough = catalog.tier(for: .mostThorough) else {
            return XCTFail("the shipped catalog must carry Most thorough")
        }
        let localized = MemoryGate.localizedRequirementText(
            for: mostThorough, installedGB: 16, language: .english
        )
        XCTAssertTrue(localized.contains("32 GB"), localized)
    }
}
