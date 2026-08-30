//
//  PromptRoutingTests.swift
//  LDACoreTests
//
//  Tests for document-type prompt routing: PromptStore's per-class extraction
//  variants and LLMExtractor's automatic routing with the override hook. The
//  LLM is faked with a prompt-recording completer, so no model is needed.
//
//  House rules: all comments and strings in English (fixtures may contain
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class PromptRoutingTests: XCTestCase {

    // MARK: - PromptStore variants

    func testGenericClassReturnsBasePromptUnchanged() {
        let store = PromptStore()
        XCTAssertEqual(
            store.extractionSystem(for: .generic),
            store.currentExtractionSystem
        )
        XCTAssertNil(PromptStore.extractionEmphasis(for: .generic))
    }

    func testEveryNonGenericClassAppendsItsEmphasis() {
        let store = PromptStore()
        for documentClass in DocumentClass.allCases where documentClass != .generic {
            guard let emphasis = PromptStore.extractionEmphasis(for: documentClass) else {
                XCTFail("\(documentClass) must define an emphasis")
                continue
            }
            let routed = store.extractionSystem(for: documentClass)
            XCTAssertTrue(
                routed.hasPrefix(store.currentExtractionSystem),
                "the base prompt (and its trained instruction) must stay verbatim"
            )
            XCTAssertTrue(routed.hasSuffix(emphasis))
            XCTAssertNotEqual(routed, store.currentExtractionSystem)
        }
    }

    func testUserEditedBasePropagatesIntoRoutedVariant() {
        let store = PromptStore()
        store.currentExtractionSystem = "Custom edited base instruction."
        let routed = store.extractionSystem(for: .contract)
        XCTAssertTrue(routed.hasPrefix("Custom edited base instruction."))
        XCTAssertTrue(routed.contains(PromptStore.extractionEmphasis(for: .contract) ?? "?"))
    }

    // MARK: - Extractor routing

    /// Records every prompt it is asked to complete and returns an empty
    /// entity list.
    private final class PromptRecordingCompleter: TextCompleter {
        private(set) var prompts: [String] = []
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            prompts.append(prompt)
            return #"{"entities":[]}"#
        }
    }

    private let judgmentText = """
    民事判决书
    （2025）浙01民终1234号
    本院认为，上诉请求不能成立。
    """

    private let genericText = "会议纪要：与会人员讨论了下季度的产品发布安排。"

    func testAutoRouteUsesJudgmentEmphasisForAJudgment() throws {
        let recorder = PromptRecordingCompleter()
        let extractor = LLMExtractor(completer: recorder)

        _ = try extractor.extractDetailed(from: judgmentText)

        let emphasis = try XCTUnwrap(PromptStore.extractionEmphasis(for: .judgment))
        XCTAssertFalse(recorder.prompts.isEmpty)
        XCTAssertTrue(
            recorder.prompts.allSatisfy { $0.contains(emphasis) },
            "every window of a judgment must carry the judgment emphasis"
        )
        XCTAssertTrue(
            recorder.prompts.allSatisfy { $0.contains("You are a legal document anonymizer.") },
            "the trained base instruction must stay in the routed prompt"
        )
    }

    func testAutoRouteLeavesGenericTextOnBasePrompt() throws {
        let recorder = PromptRecordingCompleter()
        let extractor = LLMExtractor(completer: recorder)

        _ = try extractor.extractDetailed(from: genericText)

        for documentClass in DocumentClass.allCases where documentClass != .generic {
            let emphasis = PromptStore.extractionEmphasis(for: documentClass) ?? ""
            XCTAssertTrue(
                recorder.prompts.allSatisfy { !$0.contains(emphasis) },
                "generic text must not carry the \(documentClass) emphasis"
            )
        }
    }

    func testForcedRouteOverridesAutoClassification() throws {
        let recorder = PromptRecordingCompleter()
        let extractor = LLMExtractor(completer: recorder, route: .forced(.letter))

        _ = try extractor.extractDetailed(from: judgmentText)

        let letterEmphasis = try XCTUnwrap(PromptStore.extractionEmphasis(for: .letter))
        let judgmentEmphasis = try XCTUnwrap(PromptStore.extractionEmphasis(for: .judgment))
        XCTAssertTrue(recorder.prompts.allSatisfy { $0.contains(letterEmphasis) })
        XCTAssertTrue(recorder.prompts.allSatisfy { !$0.contains(judgmentEmphasis) })
    }

    func testForcedGenericDisablesRoutingEntirely() throws {
        let recorder = PromptRecordingCompleter()
        let extractor = LLMExtractor(completer: recorder, route: .forced(.generic))

        _ = try extractor.extractDetailed(from: judgmentText)

        let judgmentEmphasis = try XCTUnwrap(PromptStore.extractionEmphasis(for: .judgment))
        XCTAssertTrue(recorder.prompts.allSatisfy { !$0.contains(judgmentEmphasis) })
    }
}
