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
import Security
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

    // MARK: - extract-profile and fill CLI tests

    // MARK: Fixtures and helpers

    // Minimal DOCX writer used by fill CLI tests. Intentionally self-contained
    // to avoid coupling to FillServiceTests fixture helpers.

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    /// Write a minimal DOCX containing the given raw text in a single paragraph.
    private func writeDocxWithText(_ text: String, named name: String? = nil) throws -> URL {
        let fileName = name ?? "clitest-\(UUID().uuidString).docx"
        let url = tempDir.appendingPathComponent(fileName)
        let escapedText = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">\(escapedText)</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.contentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.relsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
        return url
    }

    /// Build a ClientPortfolio saved as an encrypted .ldaprofile and return
    /// the profile URL. Uses passphrase protection for test hermeticity.
    private func writeProfileWithCompanyName(
        _ companyName: String,
        label: String = "TestCo",
        named name: String? = nil
    ) throws -> URL {
        let field = ProfileField(
            key: .companyName,
            value: companyName,
            sourceDocument: "test",
            sourceSnippet: companyName,
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let profile = ClientPortfolio(
            label: label,
            fields: [field],
            sourceDocuments: ["test"],
            createdAtISO8601: fixedTimestamp,
            incomplete: false
        )
        let fileName = name ?? "test-\(UUID().uuidString).ldaprofile"
        let url = tempDir.appendingPathComponent(fileName)
        try ProfileStore.save(profile, to: url, protection: .passphrase(passphrase))
        return url
    }

    /// Build a profile with two directorName fields (ambiguous synonym hit) saved
    /// as an encrypted .ldaprofile and return the profile URL.
    private func writeProfileWithTwoDirectors() throws -> URL {
        let d1 = ProfileField(
            key: .directorName,
            value: "Alice Smith",
            sourceDocument: "test",
            sourceSnippet: "Director Alice Smith",
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let d2 = ProfileField(
            key: .directorName,
            value: "Bob Jones",
            sourceDocument: "test",
            sourceSnippet: "Director Bob Jones",
            snippetVerified: true,
            confidence: 1.0,
            userEdited: false
        )
        let profile = ClientPortfolio(
            label: "TwoDirectors",
            fields: [d1, d2],
            sourceDocuments: ["test"],
            createdAtISO8601: fixedTimestamp,
            incomplete: false
        )
        let url = tempDir.appendingPathComponent("two-directors.ldaprofile")
        try ProfileStore.save(profile, to: url, protection: .passphrase(passphrase))
        return url
    }

    /// A fake completer that returns a canned extraction JSON row.
    private final class FakeExtractCompleter: TextCompleter {
        let row: String
        init(companyName: String) {
            self.row = """
            [{"key":"companyName","value":"\(companyName)","snippet":"company is \(companyName)","confidence":0.95}]
            """
        }
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return row
        }
    }

    // MARK: extract-profile: summary contains keys but no field values

    func testExtractProfileSummaryContainsKeysButNoValues() throws {
        let sourceURL = tempDir.appendingPathComponent("cert.txt")
        let companyName = "PrivateCo Holdings Ltd"
        try Data("The company name is \(companyName).".utf8).write(to: sourceURL)

        let fake = FakeExtractCompleter(companyName: companyName)
        LDAService.makeCompleterForTesting = { fake }
        defer { LDAService.makeCompleterForTesting = nil }

        let outURL = tempDir.appendingPathComponent("matter.ldaprofile")

        let (summary, _) = try LDACLI.runExtractProfile(
            sources: [sourceURL],
            label: "TestCo",
            out: outURL,
            passphrase: passphrase,
            llmModelPath: "fake-model.gguf",
            timestamp: { self.fixedTimestamp }
        )

        let json = try CLIJSON.encode(summary)

        // The summary must list the rawKey.
        XCTAssertTrue(
            summary.keys.contains("companyName"),
            "summary.keys must include companyName"
        )

        // The JSON must not contain the company name value (no PII leak).
        XCTAssertFalse(
            json.contains(companyName),
            "extract-profile summary JSON must not contain field values"
        )

        // The profile must exist on disk.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outURL.path),
            "profile file must be written to disk"
        )

        // profilePath in summary must match outURL.
        XCTAssertEqual(summary.profilePath, outURL.path)
    }

    // MARK: extract-profile: failedSources captured in summary

    func testExtractProfileSummaryReportsFailedSources() throws {
        let goodURL = tempDir.appendingPathComponent("cert.txt")
        try Data("The company name is Acme Corp.".utf8).write(to: goodURL)
        let badURL = tempDir.appendingPathComponent("ghost.txt")

        let fake = FakeExtractCompleter(companyName: "Acme Corp")
        LDAService.makeCompleterForTesting = { fake }
        defer { LDAService.makeCompleterForTesting = nil }

        let outURL = tempDir.appendingPathComponent("failed-sources.ldaprofile")

        let (summary, _) = try LDACLI.runExtractProfile(
            sources: [goodURL, badURL],
            label: "Acme",
            out: outURL,
            passphrase: passphrase,
            llmModelPath: "fake",
            timestamp: { self.fixedTimestamp }
        )

        XCTAssertEqual(summary.failedSources.count, 1)
        XCTAssertEqual(summary.failedSources[0].name, badURL.lastPathComponent)
        XCTAssertFalse(summary.failedSources[0].reason.isEmpty)
    }

    // MARK: fill --plan: output contains proposed values; ambiguous blank carries candidates

    func testFillPlanOutputContainsProposedValue() throws {
        let profileURL = try writeProfileWithCompanyName("Acme Holdings Limited")
        let docxURL = try writeDocxWithText("Registered name: [Company Name].")

        let entries = try LDACLI.runFillPlan(
            profile: profileURL,
            passphrase: passphrase,
            input: docxURL
        )

        // At least one proposed entry for the Company Name blank.
        let proposed = entries.filter { $0.status == "proposed" }
        XCTAssertFalse(proposed.isEmpty, "Expected at least one proposed blank")

        let companyEntry = proposed.first { $0.proposedFieldKey == "companyName" }
        XCTAssertNotNil(companyEntry, "Expected a proposed blank with key companyName")
        XCTAssertEqual(companyEntry?.proposedValue, "Acme Holdings Limited")
        XCTAssertNil(companyEntry?.candidates, "Unambiguous blank must not carry candidates")
    }

    func testFillPlanAmbiguousBlankCarriesCandidates() throws {
        let profileURL = try writeProfileWithTwoDirectors()
        // A blank labeled "Director" triggers the directorName synonym which has
        // two fields: ambiguous hit.
        let docxURL = try writeDocxWithText("Appointed director: [Director].")

        let entries = try LDACLI.runFillPlan(
            profile: profileURL,
            passphrase: passphrase,
            input: docxURL
        )

        let ambiguous = entries.first { $0.status == "proposed" && $0.proposedFieldKey == nil }
        XCTAssertNotNil(ambiguous, "Expected an ambiguous proposed blank")

        // candidates must be present and contain the directorName rawKey (both entries).
        let candidates = ambiguous?.candidates
        XCTAssertNotNil(candidates, "Ambiguous blank must carry candidates")
        XCTAssertEqual(candidates?.count, 2, "Expected two candidate rawKeys (two directorName fields)")
        XCTAssertTrue(
            candidates?.allSatisfy { $0 == "directorName" } ?? false,
            "All candidates for an ambiguous directorName hit must have rawKey directorName"
        )
    }

    // MARK: CLIRuntimeError message mapping

    func testStaleTargetRendersReadableMessage() {
        let detail = "offset 10-25"
        let error = LDAServiceError.staleTarget(detail: detail)
        let runtimeError = CLIRuntimeError(error)
        let message = runtimeError.description
        XCTAssertTrue(
            message.contains("Re-run fill --plan"),
            "staleTarget message must contain 'Re-run fill --plan', got: \(message)"
        )
        XCTAssertTrue(
            message.contains(detail),
            "staleTarget message must include the detail string, got: \(message)"
        )
    }

    // MARK: fill --apply: writes filled file and prints value-free report

    func testFillApplyWritesFilledDocxAndReturnsValueFreeReport() throws {
        let companyName = "FillApply Corp"
        let profileURL = try writeProfileWithCompanyName(companyName)
        let docxURL = try writeDocxWithText("Company: [Company Name]. Jurisdiction: [Jurisdiction].")
        let outDir = tempDir.appendingPathComponent("filled-out", isDirectory: true)

        let report = try LDACLI.runFillApply(
            profile: profileURL,
            passphrase: passphrase,
            input: docxURL,
            outputDir: outDir
        )

        // The filled file must exist.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: report.outputURL.path),
            "Filled output file must exist"
        )

        // At least one blank was filled.
        XCTAssertGreaterThan(report.filledCount, 0, "Expected at least one filled blank")

        // The FillReport JSON must not contain the company name value.
        let reportJSON = try CLIJSON.encode(FillReportJSON(report: report))
        XCTAssertFalse(
            reportJSON.contains(companyName),
            "fill --apply report JSON must not contain filled values"
        )
    }

    // MARK: fill mutual exclusion validation

    func testFillMutualExclusionBothFlagsThrows() throws {
        // Passing both --plan and --apply must throw a validation error.
        XCTAssertThrowsError(
            try Fill.parse(["--profile", "x.ldaprofile",
                            "--input", "x.docx",
                            "--plan",
                            "--apply",
                            "--output-dir", "out/"])
        ) { error in
            // ArgumentParser wraps validation errors; ensure the error is related
            // to the mutual-exclusion check (not a missing-argument error).
            let desc = String(describing: error)
            XCTAssertTrue(
                desc.lowercased().contains("mutually exclusive") ||
                desc.lowercased().contains("exclusive"),
                "Expected mutual-exclusion validation error, got: \(desc)"
            )
        }
    }

    func testFillNeitherFlagThrows() throws {
        // Passing neither --plan nor --apply must throw.
        XCTAssertThrowsError(
            try Fill.parse(["--profile", "x.ldaprofile", "--input", "x.docx"])
        ) { error in
            let desc = String(describing: error)
            XCTAssertFalse(desc.isEmpty, "Expected a non-empty validation error")
        }
    }

    func testFillApplyWithoutOutputDirThrows() throws {
        // --apply without --output-dir must throw a validation error.
        XCTAssertThrowsError(
            try Fill.parse(["--profile", "x.ldaprofile", "--input", "x.docx", "--apply"])
        ) { error in
            let desc = String(describing: error)
            XCTAssertTrue(
                desc.lowercased().contains("output-dir"),
                "Expected output-dir validation error, got: \(desc)"
            )
        }
    }

    // MARK: ArgumentParser parsing

    func testExtractProfileParsingAcceptsMultipleSources() throws {
        let cmd = try ExtractProfile.parse([
            "--label", "Acme",
            "--out", "/tmp/matter.ldaprofile",
            "--model", "/tmp/model.gguf",
            "cert.pdf", "articles.pdf"
        ])
        XCTAssertEqual(cmd.label, "Acme")
        XCTAssertEqual(cmd.out, "/tmp/matter.ldaprofile")
        XCTAssertEqual(cmd.model, "/tmp/model.gguf")
        XCTAssertEqual(cmd.sources, ["cert.pdf", "articles.pdf"])
        XCTAssertNil(cmd.passphrase)
    }

    func testExtractProfileParsingWithPassphrase() throws {
        let cmd = try ExtractProfile.parse([
            "--label", "Acme",
            "--out", "/tmp/matter.ldaprofile",
            "--passphrase", "secret123",
            "--model", "/tmp/model.gguf",
            "cert.pdf"
        ])
        XCTAssertEqual(cmd.passphrase, "secret123")
        XCTAssertEqual(cmd.sources, ["cert.pdf"])
    }

    func testExtractProfileNoSourcesThrowsValidation() throws {
        XCTAssertThrowsError(
            try ExtractProfile.parse([
                "--label", "Acme",
                "--out", "/tmp/matter.ldaprofile",
                "--model", "/tmp/model.gguf"
            ])
        )
    }

    func testFillPlanParsingAcceptsOptionalModel() throws {
        let cmd = try Fill.parse([
            "--profile", "matter.ldaprofile",
            "--input", "draft.docx",
            "--plan"
        ])
        XCTAssertEqual(cmd.profile, "matter.ldaprofile")
        XCTAssertEqual(cmd.input, "draft.docx")
        XCTAssertTrue(cmd.plan)
        XCTAssertFalse(cmd.apply)
        XCTAssertNil(cmd.model)
        XCTAssertNil(cmd.outputDir)
    }

    func testFillApplyParsingAcceptsAllOptions() throws {
        let cmd = try Fill.parse([
            "--profile", "matter.ldaprofile",
            "--passphrase", "pw",
            "--input", "draft.docx",
            "--model", "/models/v2.gguf",
            "--apply",
            "--output-dir", "out/"
        ])
        XCTAssertEqual(cmd.profile, "matter.ldaprofile")
        XCTAssertEqual(cmd.passphrase, "pw")
        XCTAssertTrue(cmd.apply)
        XCTAssertFalse(cmd.plan)
        XCTAssertEqual(cmd.model, "/models/v2.gguf")
        XCTAssertEqual(cmd.outputDir, "out/")
    }

}
