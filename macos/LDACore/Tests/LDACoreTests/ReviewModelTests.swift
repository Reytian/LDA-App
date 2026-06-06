//
//  ReviewModelTests.swift
//  LDACoreTests
//
//  Tests for the LDAUI ReviewModel view-model. They exercise the deterministic
//  open + detect path (useLLM = false, so the GGUF model is never required), the
//  accept/reject toggle, and the export path that tokenizes the accepted spans,
//  writes the redacted .txt edit surface, and saves the encrypted .ldamap sidecar.
//
//  ReviewModel is @MainActor isolated, so the suite is annotated @MainActor and
//  uses XCTest to match the rest of the project's test convention.
//
//  Every fixture is generated at runtime under FileManager.temporaryDirectory, so
//  the tests are hermetic and leave nothing behind.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ReviewModelTests: XCTestCase {

    // MARK: - Constants

    /// A checksum-valid Chinese resident identity card number (ISO-7064 mod-11-2).
    /// Asserted valid in setUp so the fixture stays self-checking; an invalid ID
    /// would be silently dropped by detection and break the test's premise.
    private static let validChineseID = "110101199003071233"

    /// An email address the deterministic engine recognizes.
    private static let email = "jane.doe@example.com"

    /// Fixed ISO-8601 timestamp; export is clock-free so the caller supplies it.
    private static let createdAt = "2026-06-06T00:00:00Z"

    /// The token the tokenizer mints for the email (first EMAIL detected).
    private static let emailToken = "{EMAIL_1}"

    /// The token the tokenizer mints for the national ID. sanitizeType strips the
    /// underscore from NATIONAL_ID, yielding the TYPE "NATIONALID".
    private static let nationalIDToken = "{NATIONALID_1}"

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        XCTAssertTrue(
            DeterministicEngine.isValidChineseID(Self.validChineseID),
            "fixture national ID must be checksum-valid"
        )
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixture

    /// Write a temporary .txt carrying an email and a checksum-valid 身份证, plus
    /// surrounding prose so non-PII text presence can be checked too.
    private func writeFixtureText() throws -> URL {
        let text = """
        Engagement Letter

        Contact the client at \(Self.email) for the file.
        The client national ID on record is \(Self.validChineseID).
        """
        let url = workDir.appendingPathComponent("engagement.txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Open and detect (deterministic only)

    func testOpenDetectsEmailAndNationalID() async throws {
        let model = ReviewModel(modelPath: nil)
        // AI detection is on by default but is a no-op here because modelPath is
        // nil, so this test exercises the deterministic path without a GGUF model.
        XCTAssertTrue(model.useLLM)

        let inputURL = try writeFixtureText()
        await model.open(inputURL)
        XCTAssertEqual(model.status, .imported, "open imports and shows the text but does not auto-detect")
        XCTAssertTrue(model.entities.isEmpty, "no detection until anonymize is called")

        await model.anonymize()
        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(model.documentText.isEmpty)

        let types = Set(model.entities.map { $0.span.type })
        XCTAssertTrue(types.contains(.email), "EMAIL must be among the detected entities")
        XCTAssertTrue(types.contains(.nationalID), "NATIONAL_ID must be among the detected entities")

        // Every entity is accepted by default and carries no token before export.
        XCTAssertTrue(model.entities.allSatisfy { $0.accepted })
        XCTAssertTrue(model.entities.allSatisfy { $0.token == nil })

        // Entities are mapped from spans sorted by ascending start offset.
        let starts = model.entities.map { $0.span.start }
        XCTAssertEqual(starts, starts.sorted(), "entities must be ordered by span start")

        // Deterministic-only: the fuzzy LLM types are never present here.
        XCTAssertFalse(types.contains(.person))
        XCTAssertFalse(types.contains(.company))
        XCTAssertFalse(types.contains(.address))
    }

    // MARK: - Reject one, accept the rest, then export

    func testExportOmitsRejectedTokenAndKeepsAcceptedOnes() async throws {
        let model = ReviewModel(modelPath: nil)
        let inputURL = try writeFixtureText()
        await model.open(inputURL)
        await model.anonymize()
        XCTAssertEqual(model.status, .ready)

        // Reject the EMAIL entity; keep the NATIONAL_ID (and any other) accepted.
        let emailEntity = try XCTUnwrap(
            model.entities.first { $0.span.type == .email },
            "fixture must yield an EMAIL entity to reject"
        )
        model.setAccepted(emailEntity.id, false)
        XCTAssertFalse(
            try XCTUnwrap(model.entities.first { $0.id == emailEntity.id }).accepted,
            "setAccepted(false) must clear the accepted flag"
        )

        let acceptedCount = model.entities.filter { $0.accepted }.count
        XCTAssertGreaterThanOrEqual(acceptedCount, 1, "the national ID stays accepted")

        // Act: export with a passphrase to a fresh directory.
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        let passphrase = "correct horse battery staple"
        let result = try model.export(
            to: outputDir,
            passphrase: passphrase,
            createdAtISO8601: Self.createdAt
        )

        // The redacted .txt and the .ldamap sidecar both exist on disk.
        XCTAssertEqual(result.redactedURL.pathExtension.lowercased(), "txt")
        XCTAssertEqual(result.mappingURL.pathExtension.lowercased(), "ldamap")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.redactedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mappingURL.path))

        // tokenCount equals the number of accepted (and therefore tokenized) entities.
        XCTAssertEqual(result.tokenCount, acceptedCount)

        // The redacted edit surface keeps the accepted national ID token, drops the
        // rejected email token, and leaks neither original surface value.
        let redactedText = try String(contentsOf: result.redactedURL, encoding: .utf8)
        XCTAssertTrue(
            redactedText.contains(Self.nationalIDToken),
            "the accepted national ID token must be present in the edit surface"
        )
        XCTAssertFalse(
            redactedText.contains(Self.emailToken),
            "the rejected email token must not appear in the edit surface"
        )
        XCTAssertFalse(redactedText.contains(Self.validChineseID), "national ID surface leaked")
        // Non-PII prose survives untouched.
        XCTAssertTrue(redactedText.contains("Engagement Letter"))

        // The sidecar decrypts back to a mapping whose entry count matches tokenCount,
        // and the rejected email surface is absent from it.
        let mapping = try MappingStore.load(
            from: result.mappingURL,
            protection: .passphrase(passphrase)
        )
        XCTAssertEqual(mapping.entries.count, result.tokenCount)
        XCTAssertFalse(
            mapping.entries.values.contains { $0.surfaceText == Self.email },
            "rejected email must not be stored in the mapping"
        )
        XCTAssertTrue(
            mapping.entries.values.contains { $0.surfaceText == Self.validChineseID },
            "accepted national ID must be stored in the mapping"
        )

        // After export, the accepted entity carries its assigned token; the rejected
        // entity carries none.
        let acceptedAfter = try XCTUnwrap(model.entities.first { $0.span.type == .nationalID })
        XCTAssertEqual(acceptedAfter.token, Self.nationalIDToken)
        let rejectedAfter = try XCTUnwrap(model.entities.first { $0.id == emailEntity.id })
        XCTAssertNil(rejectedAfter.token, "a rejected entity must not be assigned a token")
    }
}
