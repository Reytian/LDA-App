//
//  TestSeamHygieneTests.swift
//  LDACoreTests
//
//  Every process-wide test seam is shared mutable state. A test that installs
//  one and does not remove it leaks a fake into every later test in the same
//  process, and the resulting failure surfaces far from its cause (a portfolio
//  test suddenly reading another suite's temp directory, a detection test
//  quietly running against a fake extractor).
//
//  assertNoTestSeamsInstalled() makes that leak fail loudly at the seam of the
//  NEXT suite instead. Suites that install seams call it at the top of setUp,
//  so the blame lands on the suite that forgot to clean up.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAMCP
@testable import LDAUI

extension XCTestCase {

    /// Fail when any process-wide test seam is still installed.
    ///
    /// Called at the START of setUp, not in tearDown: most suites clear their
    /// seams in tearDown, so asserting there would be vacuous. Asserting on
    /// entry checks the invariant that actually matters, that this suite starts
    /// from an uninstrumented process.
    func assertNoTestSeamsInstalled(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let installed = TestSeamRegistry.installedSeamNames()
        XCTAssertTrue(
            installed.isEmpty,
            "Test seams leaked from an earlier test: \(installed.joined(separator: ", ")). "
                + "Whichever test installed them must clear them in tearDown or a defer.",
            file: file,
            line: line
        )
    }
}

/// One place that knows every seam, so a newly added seam is caught by adding
/// a single line here rather than by remembering to update several tearDowns.
enum TestSeamRegistry {

    static func installedSeamNames() -> [String] {
        var names: [String] = []
        // LDACore facade
        if LDAService.extractorSeam.isInstalled { names.append("LDAService.makeExtractorForTesting") }
        if LDAService.completerSeam.isInstalled { names.append("LDAService.makeCompleterForTesting") }
        // MCP server
        if MCPServer.librarySeam.isInstalled { names.append("MCPServer.libraryRootForTesting") }
        // Fill view model
        if FillModel.extractProfileSeam.isInstalled { names.append("FillModel.extractProfileForTesting") }
        if FillModel.planFillSeam.isInstalled { names.append("FillModel.planFillForTesting") }
        if FillModel.applyFillSeam.isInstalled { names.append("FillModel.applyFillForTesting") }
        if FillModel.librarySeam.isInstalled { names.append("FillModel.libraryForTesting") }
        if FillModel.libraryRootSeam.isInstalled { names.append("FillModel.libraryRootForTesting") }
        // Review view model
        if ReviewModel.detectDelaySeam.isInstalled { names.append("ReviewModel.detectDelayForTesting") }
        if ReviewModel.llmExtractorSeam.isInstalled { names.append("ReviewModel.llmExtractorFactoryForTesting") }
        // Infrastructure seams
        if ImportLimits.archiveBudgetSeam.isInstalled { names.append("ImportLimits.archiveBudgetSeam") }
        if EncryptedContainer.clockSeam.isInstalled { names.append("EncryptedContainer.clockSeam") }
        return names
    }

    static func clearAll() {
        LDAService.extractorSeam.clear()
        LDAService.completerSeam.clear()
        MCPServer.librarySeam.clear()
        FillModel.extractProfileSeam.clear()
        FillModel.planFillSeam.clear()
        FillModel.applyFillSeam.clear()
        FillModel.librarySeam.clear()
        FillModel.libraryRootSeam.clear()
        ReviewModel.detectDelaySeam.clear()
        ReviewModel.llmExtractorSeam.clear()
        ImportLimits.archiveBudgetSeam.clear()
        EncryptedContainer.clockSeam.clear()
    }
}

final class TestSeamHygieneTests: XCTestCase {

    override func tearDown() {
        TestSeamRegistry.clearAll()
        super.tearDown()
    }

    func testSeamsAreClearedByDefault() {
        TestSeamRegistry.clearAll()
        assertNoTestSeamsInstalled()
    }

    func testAnInstalledSeamIsDetected() {
        // Arrange
        TestSeamRegistry.clearAll()

        // Act
        LDAService.makeExtractorForTesting = { _ in nil }

        // Assert
        XCTAssertEqual(
            TestSeamRegistry.installedSeamNames(),
            ["LDAService.makeExtractorForTesting"],
            "the registry must name the seam that leaked, not merely that one did"
        )
    }

    func testClearAllRemovesEverySeam() {
        // Arrange
        LDAService.makeExtractorForTesting = { _ in nil }
        LDAService.makeCompleterForTesting = { FakeSeamCompleter() }
        MCPServer.libraryRootForTesting = URL(fileURLWithPath: "/tmp")
        ReviewModel.detectDelayForTesting = 0.01
        XCTAssertFalse(TestSeamRegistry.installedSeamNames().isEmpty)

        // Act
        TestSeamRegistry.clearAll()

        // Assert
        XCTAssertTrue(TestSeamRegistry.installedSeamNames().isEmpty)
    }

    func testSeamAccessIsSerialized() {
        // A bare mutable static would race here. The seam is lock guarded, so
        // concurrent writers only have to agree on a final value, not avoid a
        // torn read of a closure reference.
        TestSeamRegistry.clearAll()
        let seam = LDAService.extractorSeam
        DispatchQueue.concurrentPerform(iterations: 64) { iteration in
            if iteration.isMultiple(of: 2) {
                seam.value = { _ in nil }
            } else {
                _ = seam.value
                _ = seam.isInstalled
            }
        }
        seam.clear()
        XCTAssertFalse(seam.isInstalled)
    }

    private final class FakeSeamCompleter: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String { "{}" }
    }
}
