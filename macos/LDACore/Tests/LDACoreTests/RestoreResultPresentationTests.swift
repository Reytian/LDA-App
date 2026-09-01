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

    func testInlineRestoreSummaryLocalizesItsCount() {
        XCTAssertEqual(
            RestoreResultPresentation.restoredSentence(1, language: .english),
            "Restored 1 value."
        )
        XCTAssertEqual(
            RestoreResultPresentation.restoredSentence(2, language: .english),
            "Restored 2 values."
        )
    }

    func testNothingAmbiguousProducesNoSentence() {
        // Arrange, Act
        let sentence = RestoreResultPresentation.ambiguousSentence(
            [],
            language: .english
        )

        // Assert
        XCTAssertNil(sentence, "a clean restore must not show an ambiguity warning")
    }

    func testASingleAmbiguousMaskReadsInTheSingular() throws {
        // Arrange, Act
        let sentence = try XCTUnwrap(
            RestoreResultPresentation.ambiguousSentence(
                ["张*明"],
                language: .english
            )
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
            RestoreResultPresentation.ambiguousSentence(
                ["张*明", "李*华"],
                language: .english
            )
        )

        // Assert
        XCTAssertTrue(sentence.contains("2 masked forms are shared"), sentence)
        XCTAssertTrue(sentence.contains("Those sites were"), sentence)
    }

    func testTheSampleIsCappedButTheCountIsNot() throws {
        // Arrange
        let masks = (1...9).map { "mask\($0)" }

        // Act
        let sentence = try XCTUnwrap(
            RestoreResultPresentation.ambiguousSentence(
                masks,
                language: .english
            )
        )

        // Assert: every mask would make the banner unreadable, so the sentence
        // lists a sample while still reporting the true total.
        XCTAssertTrue(sentence.contains("9 masked forms"), sentence)
        XCTAssertTrue(sentence.contains("mask5"), "the sample runs to the limit")
        XCTAssertFalse(sentence.contains("mask6"), "the sample stops at the limit")
    }

    func testTheSentenceCarriesNoEmDash() throws {
        // Arrange, Act
        let sentence = try XCTUnwrap(
            RestoreResultPresentation.ambiguousSentence(
                ["张*明"],
                language: .english
            )
        )

        // Assert: house rule, and these strings are user-visible.
        XCTAssertFalse(sentence.contains("\u{2014}"), "no em-dash in shipped copy")
        XCTAssertFalse(sentence.contains("\u{2013}"), "no en-dash in shipped copy")
    }

    func testCleanResultUsesFrenchSingularAndPluralAndPreservesFileName() {
        let fileName = "Contrat 100% 张三.docx"

        let singular = RestoreResultPresentation.cleanResult(
            restoredCount: 1,
            outputFileName: fileName,
            language: .french
        )
        let plural = RestoreResultPresentation.cleanResult(
            restoredCount: 3,
            outputFileName: fileName,
            language: .french
        )

        XCTAssertEqual(singular, "1 valeur a été restaurée dans \(fileName).")
        XCTAssertEqual(plural, "3 valeurs ont été restaurées dans \(fileName).")
    }

    func testOrphanWarningUsesFrenchSingularAndCapsPluralSample() throws {
        let singular = try XCTUnwrap(
            RestoreResultPresentation.orphanSentence(
                ["{PERSON_1}"],
                language: .french
            )
        )
        let tokens = (1...7).map { "{PERSON_\($0)}" }
        let plural = try XCTUnwrap(
            RestoreResultPresentation.orphanSentence(
                tokens,
                language: .french
            )
        )

        XCTAssertEqual(
            singular,
            "1 espace réservé n’a pas pu être associé : {PERSON_1}."
        )
        XCTAssertTrue(plural.hasPrefix("7 espaces réservés n’ont pas pu être associés :"), plural)
        XCTAssertTrue(plural.contains("{PERSON_5}"), plural)
        XCTAssertFalse(plural.contains("{PERSON_6}"), plural)
    }

    func testDamagedPlaceholderWarningUsesSimplifiedChineseAndPreservesSamples() throws {
        let samples = ["{PERSON_1", "{ORG_2 }"]

        let sentence = try XCTUnwrap(
            RestoreResultPresentation.damagedSentence(
                samples,
                language: .simplifiedChinese
            )
        )

        XCTAssertEqual(
            sentence,
            "有 2 个占位符似乎在编辑时受损：{PERSON_1, {ORG_2 }。"
        )
    }

    func testAmbiguityWarningUsesTraditionalChineseSingularCopy() throws {
        let sentence = try XCTUnwrap(
            RestoreResultPresentation.ambiguousSentence(
                ["張*明"],
                language: .traditionalChinese
            )
        )

        XCTAssertEqual(
            sentence,
            "1 個遮罩形式由多個實體共用：張*明。該位置保持原樣，未作猜測；請根據您自己的記錄進行核對。"
        )
    }

    func testWarningResultUsesChineseCopyAndPreservesFileNameAndProblems() {
        let fileName = "原文 100%.docx"
        let problem = "{PERSON_1} 无法匹配。"

        let result = RestoreResultPresentation.warningResult(
            restoredCount: 1,
            problems: [problem],
            outputFileName: fileName,
            language: .simplifiedChinese
        )

        XCTAssertEqual(
            result,
            "已恢复 1 个值，但有警告。 \(problem) 未作任何猜测；请在 \(fileName) 中检查这些内容并手动修正。"
        )
    }

    func testWarningResultUsesFrenchPluralCopy() {
        let result = RestoreResultPresentation.warningResult(
            restoredCount: 2,
            problems: ["Un avertissement."],
            outputFileName: "sortie.docx",
            language: .french
        )

        XCTAssertTrue(
            result.hasPrefix("2 valeurs ont été restaurées avec des avertissements."),
            result
        )
    }

    func testFailureResultLocalizesPrefixAndPreservesErrorDescription() {
        let description = "NSCocoaErrorDomain 100% 原因"

        let result = RestoreResultPresentation.failureResult(
            errorDescription: description,
            language: .traditionalChinese
        )

        XCTAssertEqual(result, "還原失敗。\(description)")
    }
}
