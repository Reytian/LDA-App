//
//  CLITests.swift
//  LDACoreTests
//
//  Tests for the LDACLI testable helpers (runAnonymize / runRestore / runDetect).
//  These exercise the core logic directly on temp fixtures rather than spawning a
//  process, so the tests stay hermetic and fast. Every fixture is generated in
//  FileManager.temporaryDirectory; no binaries are committed.
//
//  Passphrase protection is used throughout so the mapping sidecar round-trips
//  without touching the macOS Keychain. The ISO-8601 stamp is injected as a fixed
//  closure so anonymize is fully deterministic.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACLI
@testable import LDACore

final class CLITests: XCTestCase {
    private var tempDir: URL!
    private let fixedTimestamp = "2026-06-06T00:00:00Z"
    private let passphrase = "correct horse battery staple"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A document with several deterministically detectable entities.
    private let sampleText = """
    Please remit payment to jane.doe@example.com or call 212-555-0147.
    The closing date is 2026-03-15 and the wire reference is 1234567890123456.
    """

    private func writeSampleTxt(named name: String = "doc.txt") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try sampleText.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - anonymize then restore round-trips

    func testAnonymizeThenRestoreReturnsOriginal() throws {
        let input = try writeSampleTxt()

        let anonymizeResult = try LDACLI.runAnonymize(
            input: input,
            outputDir: tempDir,
            passphrase: passphrase,
            timestamp: { self.fixedTimestamp }
        )

        // The redacted edit surface and the .ldamap sidecar both exist.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: anonymizeResult.redactedFileURL.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: anonymizeResult.mappingFileURL.path)
        )
        XCTAssertEqual(anonymizeResult.mappingFileURL.pathExtension, "ldamap")
        XCTAssertGreaterThan(anonymizeResult.entityCount, 0)
        XCTAssertNil(anonymizeResult.visualPdfURL, "Text input has no review PDF")

        // The edit surface must not contain the original PII values.
        let redacted = try String(
            contentsOf: anonymizeResult.redactedFileURL,
            encoding: .utf8
        )
        XCTAssertFalse(redacted.contains("jane.doe@example.com"))
        XCTAssertTrue(redacted.contains("{"))

        // Restore via the produced .ldamap returns the original text exactly.
        let output = tempDir.appendingPathComponent("restored.txt")
        let restoreReport = try LDACLI.runRestore(
            input: anonymizeResult.redactedFileURL,
            mapping: anonymizeResult.mappingFileURL,
            output: output,
            passphrase: passphrase
        )

        let restoredText = try String(contentsOf: output, encoding: .utf8)
        XCTAssertEqual(restoredText, sampleText)
        XCTAssertGreaterThan(restoreReport.restoredCount, 0)
        XCTAssertEqual(restoreReport.orphanTokens, [])
        XCTAssertEqual(restoreReport.outputURL.path, output.path)
    }

    func testAnonymizeStampsInjectedTimestampDeterministically() throws {
        let input = try writeSampleTxt()

        let result = try LDACLI.runAnonymize(
            input: input,
            outputDir: tempDir,
            passphrase: passphrase,
            timestamp: { self.fixedTimestamp }
        )

        let mapping = try MappingStore.load(
            from: result.mappingFileURL,
            protection: .passphrase(passphrase)
        )
        XCTAssertEqual(mapping.createdAtISO8601, fixedTimestamp)
        XCTAssertEqual(mapping.sourceFile, input.lastPathComponent)
    }

    // MARK: - detect

    func testDetectReturnsExpectedEntities() throws {
        let input = try writeSampleTxt()

        let spans = try LDACLI.runDetect(input: input)

        let types = Set(spans.map { $0.type })
        XCTAssertTrue(types.contains(.email), "Expected an EMAIL entity")
        XCTAssertTrue(types.contains(.phone), "Expected a PHONE entity")
        XCTAssertTrue(types.contains(.date), "Expected a DATE entity")

        // The detected email surface text round-trips to the source text exactly.
        let email = spans.first { $0.type == .email }
        XCTAssertEqual(email?.text, "jane.doe@example.com")
        XCTAssertEqual(email?.source, .deterministic)

        // Spans are returned sorted by start ascending (SpanMerger contract).
        let starts = spans.map { $0.start }
        XCTAssertEqual(starts, starts.sorted())
    }

    func testDetectJSONShapeMatchesContract() throws {
        let input = try writeSampleTxt()
        let spans = try LDACLI.runDetect(input: input)

        let entities = spans.map(DetectedEntityJSON.init)
        let json = try CLIJSON.encode(entities)

        // The JSON is a decodable array carrying the contract fields.
        let decoded = try JSONDecoder().decode([DetectedEntityJSON].self, from: Data(json.utf8))
        XCTAssertEqual(decoded, entities)
        XCTAssertTrue(decoded.contains { $0.type == "EMAIL" })
    }

    // MARK: - error mapping

    func testMissingInputYieldsMappedError() {
        let missing = tempDir.appendingPathComponent("nope.txt")

        XCTAssertThrowsError(try LDACLI.runDetect(input: missing)) { error in
            guard case CLIError.inputNotFound(let path) = error else {
                return XCTFail("Expected CLIError.inputNotFound, got \(error)")
            }
            XCTAssertEqual(path, missing.path)
        }
    }

    func testAnonymizeMissingInputYieldsMappedError() {
        let missing = tempDir.appendingPathComponent("ghost.txt")

        XCTAssertThrowsError(
            try LDACLI.runAnonymize(
                input: missing,
                outputDir: tempDir,
                passphrase: passphrase,
                timestamp: { self.fixedTimestamp }
            )
        ) { error in
            guard case CLIError.inputNotFound = error else {
                return XCTFail("Expected CLIError.inputNotFound, got \(error)")
            }
        }
    }

    func testRestoreMissingMappingYieldsMappedError() throws {
        let input = try writeSampleTxt()
        let result = try LDACLI.runAnonymize(
            input: input,
            outputDir: tempDir,
            passphrase: passphrase,
            timestamp: { self.fixedTimestamp }
        )
        let missingMapping = tempDir.appendingPathComponent("absent.ldamap")
        let output = tempDir.appendingPathComponent("restored.txt")

        XCTAssertThrowsError(
            try LDACLI.runRestore(
                input: result.redactedFileURL,
                mapping: missingMapping,
                output: output,
                passphrase: passphrase
            )
        ) { error in
            guard case CLIError.inputNotFound = error else {
                return XCTFail("Expected CLIError.inputNotFound, got \(error)")
            }
        }
    }

    // MARK: - wrong passphrase

    func testRestoreWithWrongPassphraseFailsToDecrypt() throws {
        let input = try writeSampleTxt()
        let result = try LDACLI.runAnonymize(
            input: input,
            outputDir: tempDir,
            passphrase: passphrase,
            timestamp: { self.fixedTimestamp }
        )
        let output = tempDir.appendingPathComponent("restored.txt")

        XCTAssertThrowsError(
            try LDACLI.runRestore(
                input: result.redactedFileURL,
                mapping: result.mappingFileURL,
                output: output,
                passphrase: "the wrong passphrase"
            )
        ) { error in
            guard case DocumentIOError.decryptionFailed = error else {
                return XCTFail("Expected DocumentIOError.decryptionFailed, got \(error)")
            }
        }
    }
}
