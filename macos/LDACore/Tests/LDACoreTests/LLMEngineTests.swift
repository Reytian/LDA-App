//
//  LLMEngineTests.swift
//  Smoke test for the on-device llama.cpp inference path. Requires the bundled
//  GGUF model. If the model is not present, the test is skipped (so the suite
//  stays green on machines without the 2.7 GB model).
//
//  Resolve order for the model path:
//    1. env LDA_MODEL_PATH
//    2. ~/Developer/lda-models/lda-v2-Q4_K_M.gguf
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDACore

final class LLMEngineTests: XCTestCase {

    private func resolveModelPath() -> String? {
        if let env = ProcessInfo.processInfo.environment["LDA_MODEL_PATH"],
           FileManager.default.fileExists(atPath: env) {
            return env
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidate = home
            .appendingPathComponent("Developer/lda-models/lda-v2-Q4_K_M.gguf")
            .path
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    func testModelLoadsOnMetalAndExtractsEntitiesEN() throws {
        guard let modelPath = resolveModelPath() else {
            throw XCTSkip("GGUF model not present; set LDA_MODEL_PATH or place it at ~/Developer/lda-models/")
        }

        let engine = try LLMEngine(config: .init(modelPath: modelPath, contextLength: 4096))

        let system = "You are a legal document anonymizer. Identify every piece of sensitive "
            + "or personally identifying information and return strict JSON. Entity types: "
            + "PERSON, COMPANY, DATE, AMOUNT, EMAIL, PHONE, ADDRESS."
        let user = "Anonymize. Return ONLY JSON with keys entities (array of {value,type}) and redacted_text.\n\n"
            + "TEXT:\nThis Engagement Letter is between Acme Corporation and John Smith, dated "
            + "January 15, 2026, john@acme.com, +1-212-555-0100, fee USD 50,000."

        let prompt = LLMEngine.buildChatMLPrompt(system: system, user: user)
        let output = try engine.complete(prompt: prompt, maxTokens: 400)

        // Thinking must be disabled by the pre-closed block, so the answer should
        // not open a reasoning monologue.
        XCTAssertFalse(output.contains("Thinking Process"), "thinking should be disabled; got: \(output.prefix(200))")

        // The model should surface the fuzzy entities (its job) by value and type.
        XCTAssertTrue(output.contains("Acme Corporation"), "missing COMPANY value; got: \(output.prefix(400))")
        XCTAssertTrue(output.contains("John Smith"), "missing PERSON value; got: \(output.prefix(400))")
        XCTAssertTrue(output.contains("PERSON"), "missing PERSON type; got: \(output.prefix(400))")
        XCTAssertTrue(output.contains("COMPANY"), "missing COMPANY type; got: \(output.prefix(400))")
    }

    func testModelExtractsChineseEntities() throws {
        guard let modelPath = resolveModelPath() else {
            throw XCTSkip("GGUF model not present")
        }

        let engine = try LLMEngine(config: .init(modelPath: modelPath, contextLength: 4096))
        let system = "You are a legal document anonymizer. Identify every piece of sensitive "
            + "or personally identifying information and return strict JSON. Entity types: "
            + "PERSON, COMPANY, DATE, AMOUNT, EMAIL, PHONE, ADDRESS."
        let user = "Anonymize. Return ONLY JSON with keys entities (array of {value,type}) and redacted_text.\n\n"
            + "TEXT:\n本协议由阿尔法科技有限公司与张伟于2026年3月10日签订，邮箱zhangwei@example.cn。"

        let prompt = LLMEngine.buildChatMLPrompt(system: system, user: user)
        let output = try engine.complete(prompt: prompt, maxTokens: 400)

        XCTAssertTrue(output.contains("阿尔法科技有限公司"), "missing ZH COMPANY; got: \(output.prefix(400))")
        XCTAssertTrue(output.contains("张伟"), "missing ZH PERSON; got: \(output.prefix(400))")
    }

    // MARK: - Stateless per-call contract (KV cache must not accumulate)

    /// LLMExtractor calls complete() once per segment and expects each call to
    /// be independent. If the KV cache carries over, every call decodes at
    /// positions after the previous call's tokens: greedy output drifts, and
    /// once the context fills, llama_decode fails and the segment is silently
    /// skipped upstream (a silent PII miss). With a small context this test
    /// overflows after a few calls unless the engine clears memory per call.
    func testRepeatedCompletionsAreStatelessAndDoNotExhaustContext() throws {
        guard let modelPath = resolveModelPath() else {
            throw XCTSkip("GGUF model not present")
        }

        // Small context so accumulation (if any) overflows quickly.
        let engine = try LLMEngine(
            config: .init(modelPath: modelPath, contextLength: 1024)
        )
        let system = "You are a legal document anonymizer. Return strict JSON. "
            + "Entity types: PERSON, COMPANY, DATE, AMOUNT, EMAIL, PHONE, ADDRESS."
        let user = "Anonymize. Return ONLY JSON with key entities (array of {value,type}).\n\n"
            + "TEXT:\nThis Services Agreement is made between Bravo Holdings LLC and "
            + "Maria Garcia, dated February 2, 2026, maria@bravo.example, fee USD 12,000, "
            + "at 99 Park Avenue, New York. Counsel for the company reviewed the schedule "
            + "of deliverables and the indemnification provisions in detail before signing."
        let prompt = LLMEngine.buildChatMLPrompt(system: system, user: user)

        // Enough calls that accumulated prompts must overflow the 1024-token
        // context if the engine fails to clear memory between calls.
        var outputs: [String] = []
        for callIndex in 0..<8 {
            do {
                let output = try engine.complete(prompt: prompt, maxTokens: 48)
                outputs.append(output)
            } catch {
                XCTFail("call \(callIndex) threw \(error); KV cache likely accumulated across calls")
                return
            }
        }

        // Greedy decoding of an identical prompt from a clean state must be
        // deterministic: every call returns byte-identical output.
        for (index, output) in outputs.enumerated() {
            XCTAssertEqual(
                output, outputs[0],
                "call \(index) diverged from call 0; per-call state is leaking"
            )
        }
    }

    // MARK: - Stop-string trimming in byte space

    func testStopSuffixTrimsASCIIStop() {
        let bytes = Array("hello<|im_end|>".utf8)
        let trimmed = LLMEngine.trimmingStopSuffix(bytes, stop: ["<|im_end|>"])
        XCTAssertEqual(trimmed, Array("hello".utf8))
    }

    func testStopSuffixTrimsMultiByteStopExactBytes() {
        let bytes = Array("你好".utf8)
        let trimmed = LLMEngine.trimmingStopSuffix(bytes, stop: ["好"])
        XCTAssertEqual(trimmed, Array("你".utf8))
    }

    func testStopSuffixNoMatchReturnsNil() {
        XCTAssertNil(LLMEngine.trimmingStopSuffix(Array("hello".utf8), stop: ["<|im_end|>"]))
        XCTAssertNil(LLMEngine.trimmingStopSuffix(Array("hello".utf8), stop: []))
    }

    func testStopSuffixPartialMultiByteTailDoesNotFalseMatch() {
        // The first two bytes of a three-byte CJK character: an incomplete
        // sequence must never register as a stop hit, and must stay untouched.
        let partial = Array("你".utf8.prefix(2))
        XCTAssertNil(LLMEngine.trimmingStopSuffix(partial, stop: ["<|im_end|>", "好"]))
    }
}
