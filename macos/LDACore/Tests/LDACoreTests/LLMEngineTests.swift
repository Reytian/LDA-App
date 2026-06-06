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
}
