//
//  RestoreResultPresentationTests.swift
//  LDACoreTests
//
//  The restore surfaces must SHOW the sites they refused to restore. A refusal
//  the user never sees reads as text that silently failed to come back.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDAUI

final class RestoreResultPresentationTests: XCTestCase {

    func testNothingAmbiguousProducesNoSentence() {
        // Arrange, Act
        let sentence = RestoreResultPresentation.ambiguousSentence([])

        // Assert
        XCTAssertNil(sentence, "a clean restore must not show an ambiguity warning")
    }

    func testASingleAmbiguousMaskReadsInTheSingular() throws {
        // Arrange, Act
        let sentence = try XCTUnwrap(
            RestoreResultPresentation.ambiguousSentence(["张*明"])
        )

        // Assert
        XCTAssertTrue(sentence.contains("1 masked form is shared"), sentence)
        XCTAssertTrue(sentence.contains("张*明"), "the mask itself must be named")
        XCTAssertTrue(sentence.contains("That site was"), sentence)
        XCTAssertTrue(
            sentence.contains("rather than guessed"),
            "the user must be told nothing was guessed"
        )
    }

    func testSeveralAmbiguousMasksReadInThePlural() throws {
        // Arrange, Act
        let sentence = try XCTUnwrap(
            RestoreResultPresentation.ambiguousSentence(["张*明", "李*华"])
        )

        // Assert
        XCTAssertTrue(sentence.contains("2 masked forms are shared"), sentence)
        XCTAssertTrue(sentence.contains("Those sites were"), sentence)
    }

    func testTheSampleIsCappedButTheCountIsNot() throws {
        // Arrange
        let masks = (1...9).map { "mask\($0)" }

        // Act
        let sentence = try XCTUnwrap(RestoreResultPresentation.ambiguousSentence(masks))

        // Assert: every mask would make the banner unreadable, so the sentence
        // lists a sample while still reporting the true total.
        XCTAssertTrue(sentence.contains("9 masked forms"), sentence)
        XCTAssertTrue(sentence.contains("mask5"), "the sample runs to the limit")
        XCTAssertFalse(sentence.contains("mask6"), "the sample stops at the limit")
    }

    func testTheSentenceCarriesNoEmDash() throws {
        // Arrange, Act
        let sentence = try XCTUnwrap(
            RestoreResultPresentation.ambiguousSentence(["张*明"])
        )

        // Assert: house rule, and these strings are user-visible.
        XCTAssertFalse(sentence.contains("\u{2014}"), "no em-dash in shipped copy")
        XCTAssertFalse(sentence.contains("\u{2013}"), "no en-dash in shipped copy")
    }
}
