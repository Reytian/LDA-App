//
//  LDAServiceLLMTests.swift
//  LDACoreTests
//
//  Tests for the LLM wiring in the LDAService facade.
//
//  Two layers:
//  - Unit (no model): with llmModelPath nil the facade behaves exactly as the
//    deterministic-only V1 path (an email in a .txt still tokenizes as EMAIL).
//    With a bogus llmModelPath (a path that does not exist) the facade still
//    SUCCEEDS, because the LLM seam degrades gracefully to an empty span list
//    rather than failing the operation.
//  - Gated integration (skipped unless the GGUF model is available): detect over
//    a short SPA sentence with llmModelPath set must surface a PERSON span and a
//    COMPANY span, which only the LLM path can produce.
//
//  Every fixture is generated at runtime under FileManager.temporaryDirectory,
//  so the tests are fully hermetic and independent.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LDAServiceLLMTests: XCTestCase {

    // MARK: - Constants

    /// An email address the deterministic engine recognizes.
    private static let email = "jane.doe@example.com"

    /// Fixed ISO-8601 timestamp; the facade is clock-free so the caller supplies it.
    private static let createdAt = "2026-06-06T00:00:00Z"

    /// A path that is guaranteed not to exist, used to prove graceful fallback.
    private static let bogusModelPath = "/nonexistent.gguf"

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Fail here if an earlier suite leaked a process-wide test seam.
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LDAServiceLLMTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Write a .txt fixture carrying an email and return its URL.
    private func writeEmailFixture() throws -> URL {
        let original = """
        Engagement Letter

        Contact the client at \(Self.email) for any questions.
        """
        let inputURL = workDir.appendingPathComponent("engagement.txt")
        try Data(original.utf8).write(to: inputURL)
        return inputURL
    }

    /// Resolve the GGUF model path for the gated integration test, or nil.
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

    // MARK: - Unit: nil model path is unchanged behavior

    func testDetectWithNilModelPathTokenizesEmailDeterministically() throws {
        // Arrange
        let inputURL = try writeEmailFixture()

        // Act
        let spans = try LDAService.detect(input: inputURL, llmModelPath: nil)

        // Assert: the deterministic engine still detects the email.
        XCTAssertTrue(
            spans.contains { $0.type == .email && $0.text == Self.email },
            "deterministic EMAIL detection must be unchanged when llmModelPath is nil"
        )
    }

    func testAnonymizeWithNilModelPathProducesEmailTokenAndRestoresExactly() throws {
        // Arrange
        let inputURL = try writeEmailFixture()
        let original = try String(contentsOf: inputURL, encoding: .utf8)
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        let passphrase = "correct horse battery staple"
        let protection = MappingProtection.passphrase(passphrase)

        // Act: anonymize, then restore, with no LLM model.
        let result = try LDAService.anonymize(
            input: inputURL,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: Self.createdAt,
            llmModelPath: nil
        )

        // Assert: an EMAIL entity was tokenized.
        XCTAssertTrue(
            result.entities.contains { $0.type == .email },
            "anonymize with nil llmModelPath must still tokenize EMAIL deterministically"
        )
        XCTAssertGreaterThanOrEqual(result.entityCount, 1)

        // The email surface value must no longer appear in the redacted text.
        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(redacted.contains(Self.email), "redacted text must not leak the email")

        // Restore round-trips back to the exact original text.
        let restoredURL = workDir.appendingPathComponent("restored.txt")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: protection,
            output: restoredURL
        )
        let restored = try String(contentsOf: report.outputURL, encoding: .utf8)
        XCTAssertEqual(restored, original, "restore must reproduce the exact original text")
    }

    // MARK: - Unit: bogus model path falls back gracefully

    func testAnonymizeWithBogusModelPathSucceedsViaGracefulFallback() throws {
        // Arrange
        let inputURL = try writeEmailFixture()
        let outputDir = workDir.appendingPathComponent("out-bogus", isDirectory: true)
        let protection = MappingProtection.passphrase("a passphrase")

        // Act + Assert: a non-existent model path must NOT throw. The LLM seam
        // degrades to an empty span list, leaving deterministic detection intact.
        let result = try LDAService.anonymize(
            input: inputURL,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: Self.createdAt,
            llmModelPath: Self.bogusModelPath
        )

        XCTAssertTrue(
            result.entities.contains { $0.type == .email },
            "graceful fallback must still yield deterministic EMAIL detection"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: result.redactedFileURL.path),
            "the redacted edit surface must be written even when the model is missing"
        )
    }

    func testDetectWithBogusModelPathSucceedsViaGracefulFallback() throws {
        // Arrange
        let inputURL = try writeEmailFixture()

        // Act: a bogus model path must not throw.
        let spans = try LDAService.detect(
            input: inputURL,
            llmModelPath: Self.bogusModelPath
        )

        // Assert: deterministic detection is unaffected by the missing model.
        XCTAssertTrue(
            spans.contains { $0.type == .email && $0.text == Self.email },
            "graceful fallback must still yield deterministic EMAIL detection"
        )
    }

    // MARK: - Incomplete extraction is surfaced, not swallowed (LJE-001)

    /// A completer that always returns a cut-off JSON array, so no segment can be
    /// fully scanned regardless of token cap. Used through the test-only extractor
    /// seam to drive LDAService's incompleteness handling without a real model.
    private struct AlwaysTruncatingCompleter: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return #"{"entities":[{"value":"Acme Corp","type":"COMPANY"},{"value":"Robert Ki"#
        }
    }

    override func tearDown() {
        // Always clear the test seam so one test never leaks into another.
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    private func writeFuzzyFixture() throws -> URL {
        let text = "The seller is Acme Corp and the signer is Robert King."
        let inputURL = workDir.appendingPathComponent("fuzzy.txt")
        try Data(text.utf8).write(to: inputURL)
        return inputURL
    }

    func testAnonymizeThrowsWhenASegmentCannotBeFullyScanned() throws {
        // Arrange: inject an extractor whose completer never stops truncating.
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: AlwaysTruncatingCompleter())
        }
        let inputURL = try writeFuzzyFixture()
        let outputDir = workDir.appendingPathComponent("out-truncate", isDirectory: true)
        let protection = MappingProtection.passphrase("a passphrase")

        // Act + Assert: the facade must NOT silently present a clean document; it
        // must surface that a segment was not fully scanned.
        XCTAssertThrowsError(
            try LDAService.anonymize(
                input: inputURL,
                outputDir: outputDir,
                protection: protection,
                createdAtISO8601: Self.createdAt,
                llmModelPath: Self.bogusModelPath
            )
        ) { error in
            guard case LDAServiceError.incompleteExtraction = error else {
                XCTFail("expected LDAServiceError.incompleteExtraction, got \(error)")
                return
            }
        }
    }

    func testDetectThrowsWhenASegmentCannotBeFullyScanned() throws {
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: AlwaysTruncatingCompleter())
        }
        let inputURL = try writeFuzzyFixture()

        XCTAssertThrowsError(
            try LDAService.detect(input: inputURL, llmModelPath: Self.bogusModelPath)
        ) { error in
            guard case LDAServiceError.incompleteExtraction = error else {
                XCTFail("expected LDAServiceError.incompleteExtraction, got \(error)")
                return
            }
        }
    }

    func testGenuinelyEmptyLLMExtractionDoesNotThrow() throws {
        // The model found no fuzzy PII (well-formed empty array). This is a clean
        // document, NOT an incomplete scan, so anonymize must succeed and still
        // tokenize the deterministic EMAIL.
        struct EmptyCompleter: TextCompleter {
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
                return #"{"entities":[],"redacted_text":""}"#
            }
        }
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: EmptyCompleter())
        }
        let inputURL = try writeEmailFixture()
        let outputDir = workDir.appendingPathComponent("out-empty", isDirectory: true)
        let protection = MappingProtection.passphrase("a passphrase")

        let result = try LDAService.anonymize(
            input: inputURL,
            outputDir: outputDir,
            protection: protection,
            createdAtISO8601: Self.createdAt,
            llmModelPath: Self.bogusModelPath
        )

        XCTAssertTrue(
            result.entities.contains { $0.type == .email },
            "a genuinely clean LLM result must not block deterministic EMAIL tokenization"
        )
    }

    // MARK: - Gated integration: real model surfaces fuzzy entities

    func testDetectWithRealModelSurfacesPersonAndCompany() throws {
        guard let modelPath = resolveModelPath() else {
            throw XCTSkip(
                "GGUF model not present; set LDA_MODEL_PATH or place it at "
                    + "~/Developer/lda-models/lda-v2-Q4_K_M.gguf"
            )
        }

        // Arrange: a sentence whose PERSON and COMPANY are fuzzy entities only the
        // LLM path can detect (the deterministic engine owns structured PII only).
        let sentence = "This SPA is between Acme Corporation and John Smith."
        let inputURL = workDir.appendingPathComponent("spa.txt")
        try Data(sentence.utf8).write(to: inputURL)

        // Act
        let spans = try LDAService.detect(input: inputURL, llmModelPath: modelPath)

        // Assert: both fuzzy types are present.
        XCTAssertTrue(
            spans.contains { $0.type == .person },
            "the LLM path must surface a PERSON span; got: \(spans)"
        )
        XCTAssertTrue(
            spans.contains { $0.type == .company },
            "the LLM path must surface a COMPANY span; got: \(spans)"
        )
    }
}
