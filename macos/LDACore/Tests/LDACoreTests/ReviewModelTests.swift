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
        // Fail here if an earlier suite leaked a process-wide test seam; this
        // suite installs ReviewModel seams itself, so it must start clean.
        assertNoTestSeamsInstalled()
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
        let result = try await model.export(
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

    // MARK: - DOCX export scrubs non-body parts

    // Seeded PII for the multi-part DOCX fixture, restricted to types the
    // DeterministicEngine recognizes so the LLM is never required here.
    private static let bodyEmail = "body.party@example.com"
    private static let headerEmail = "header.party@example.com"
    private static let footerPhone = "+1 212 555 0188"
    private static let creatorName = "Confidential Author"
    private static let mailtoTarget = "mailto:header.party@example.com"

    /// The UI export path for a .docx must scrub PII from EVERY part of the
    /// package (headers, footers, docProps author metadata, external mailto
    /// hyperlink targets), not only the body, mirroring LDAService.anonymize.
    /// The body must still round-trip (token present, surface gone).
    func testDocxExportRedactsNonBodyParts() async throws {
        let model = ReviewModel(modelPath: nil)
        let inputURL = try writeFixtureDocxWithNonBodyPII()
        await model.open(inputURL)
        await model.anonymize()
        XCTAssertEqual(model.status, .ready)

        // The body email is detected over documentText and accepted by default.
        XCTAssertTrue(
            model.entities.contains { $0.span.text == Self.bodyEmail },
            "fixture body must yield the body email entity"
        )

        let outputDir = workDir.appendingPathComponent("docx-out", isDirectory: true)
        let result = try await model.export(
            to: outputDir,
            passphrase: "pw",
            createdAtISO8601: Self.createdAt
        )

        // The edit surface is a .docx.
        XCTAssertEqual(result.redactedURL.pathExtension.lowercased(), "docx")
        let redacted = result.redactedURL

        // Body PII gone and tokenized (the existing guarantee).
        let body = try DocxImporter().importDocument(redacted).text
        XCTAssertFalse(body.contains(Self.bodyEmail), "body email surface must be redacted")
        XCTAssertTrue(body.contains("{"), "body email should be tokenized")

        // Header and footer PII gone (the gap this test guards).
        let header = try readDocxPart("word/header1.xml", from: redacted)
        XCTAssertFalse(header.contains(Self.headerEmail), "header email must be redacted")
        let footer = try readDocxPart("word/footer1.xml", from: redacted)
        XCTAssertFalse(footer.contains(Self.footerPhone), "footer phone must be redacted")

        // docProps author metadata scrubbed.
        let core = try readDocxPart("docProps/core.xml", from: redacted)
        XCTAssertFalse(core.contains(Self.creatorName), "creator metadata must be scrubbed")

        // External mailto hyperlink target neutralized in the .rels.
        let rels = try readDocxPart("word/_rels/document.xml.rels", from: redacted)
        XCTAssertFalse(rels.contains(Self.mailtoTarget), "external mailto target must be neutralized")
    }

    // MARK: - Restore round-trip (in-app de-anonymize)

    func testRestoreRoundTripsAnExportedDocument() async throws {
        let model = ReviewModel(modelPath: nil)
        let inputURL = try writeFixtureText()
        await model.open(inputURL)
        await model.anonymize()

        let outDir = workDir.appendingPathComponent("out", isDirectory: true)
        let exportResult = try await model.export(
            to: outDir,
            passphrase: "pw",
            createdAtISO8601: Self.createdAt
        )

        let restoredURL = workDir.appendingPathComponent("restored.txt")
        let report = try model.restore(
            editedRedacted: exportResult.redactedURL,
            mapping: exportResult.mappingURL,
            passphrase: "pw",
            output: restoredURL
        )

        let original = try String(contentsOf: inputURL, encoding: .utf8)
        let restored = try String(contentsOf: restoredURL, encoding: .utf8)
        XCTAssertEqual(restored, original, "restore must reproduce the original text")
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertGreaterThan(report.restoredCount, 0)
    }

    // MARK: - Tracked changes

    /// The importer counts tracked-change containers; the model surfaces the
    /// count at open time so the shell can warn before redacting, and clears
    /// it again when a plain document replaces the revised one.
    func testOpenSurfacesTheDocxTrackedChangeCount() async throws {
        let revised = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact "),
                "<w:ins w:id=\"1\" w:author=\"a\" w:date=\"d\">"
                    + DocxTestPackage.run("jane.doe@example.com") + "</w:ins>",
                "<w:del w:id=\"2\" w:author=\"a\" w:date=\"d\"><w:r><w:delText>old</w:delText></w:r></w:del>"
            ),
            to: workDir.appendingPathComponent("revised.docx")
        )
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false

        await model.open(revised)

        XCTAssertEqual(model.trackedChangeCount, 2, "one w:ins and one w:del")
        guard case .imported = model.status else {
            return XCTFail("expected the document to import, got \(model.status)")
        }

        let plain = workDir.appendingPathComponent("plain.txt")
        try Data("No revisions.".utf8).write(to: plain)
        await model.open(plain)

        XCTAssertEqual(model.trackedChangeCount, 0, "the count belongs to the open document")
    }

    // MARK: - DOCX fixture authoring

    /// Read one part of a .docx package as a UTF-8 string for assertions.
    private func readDocxPart(_ path: String, from docx: URL) throws -> String {
        let data = try DocxZip.readEntry(path, from: docx)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Build a multi-part .docx in code: a body paragraph plus a header, footer,
    /// docProps author metadata, and an external mailto hyperlink target, each
    /// carrying deterministic-detectable PII. Mirrors the fixture style used by
    /// DocxNonBodyPartsTests so no binary fixtures are committed.
    private func writeFixtureDocxWithNonBodyPII() throws -> URL {
        let url = workDir.appendingPathComponent("engagement.docx")

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        <Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>
        <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
        </Types>
        """

        let packageRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
        </Relationships>
        """

        let documentRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId10" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
        <Relationship Id="rId11" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
        <Relationship Id="rId12" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="\(Self.mailtoTarget)" TargetMode="External"/>
        </Relationships>
        """

        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>
        <w:p><w:r><w:t xml:space="preserve">Contact the client at \(Self.bodyEmail) for the file.</w:t></w:r></w:p>
        </w:body>
        </w:document>
        """

        let headerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:hdr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:p><w:r><w:t xml:space="preserve">Confidential memo for \(Self.headerEmail)</w:t></w:r></w:p>
        </w:hdr>
        """

        let footerXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:p><w:r><w:t xml:space="preserve">Call \(Self.footerPhone) with questions</w:t></w:r></w:p>
        </w:ftr>
        """

        let coreXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:creator>\(Self.creatorName)</dc:creator>
        <cp:lastModifiedBy>\(Self.creatorName)</cp:lastModifiedBy>
        </cp:coreProperties>
        """

        try DocxZip.writeArchive(parts: [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(packageRels.utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
            ("word/_rels/document.xml.rels", Data(documentRels.utf8)),
            ("word/header1.xml", Data(headerXML.utf8)),
            ("word/footer1.xml", Data(footerXML.utf8)),
            ("docProps/core.xml", Data(coreXML.utf8))
        ], to: url)
        return url
    }
    // MARK: - Stale detection must not land on a newer document

    /// Opening document B while document A's detection is still running must
    /// discard A's late results: showing A's detections over B's text is the
    /// worst possible failure for a review tool.
    func testOpeningSecondDocumentDiscardsStaleDetection() async throws {
        let urlA = workDir.appendingPathComponent("a.txt")
        try Data("Contact \(Self.email) now.".utf8).write(to: urlA)
        let urlB = workDir.appendingPathComponent("b.txt")
        try Data("No sensitive content in this one.".utf8).write(to: urlB)

        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        await model.open(urlA)

        ReviewModel.detectDelayForTesting = 0.4
        defer { ReviewModel.detectDelayForTesting = nil }

        let detection = Task { await model.anonymize() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await model.open(urlB)
        _ = await detection.value

        XCTAssertEqual(model.status, .imported, "doc B must stay imported; stale run flipped it")
        XCTAssertTrue(model.entities.isEmpty, "doc A's stale entities landed on doc B")
        XCTAssertTrue(model.documentText.contains("No sensitive content"))
    }

    // MARK: - LLM failure must be loud

    /// A model file that exists but fails to load must NOT report AI as active;
    /// the lawyer would otherwise trust a pattern-matching-only pass as an AI
    /// pass. The failure surfaces as a warning.
    func testCorruptModelFileSurfacesAiInactiveWithWarning() async throws {
        let url = workDir.appendingPathComponent("c.txt")
        try Data("Contact \(Self.email) now.".utf8).write(to: url)
        let garbageModel = workDir.appendingPathComponent("fake.gguf")
        try Data("this is not a gguf model".utf8).write(to: garbageModel)

        let model = ReviewModel(modelPath: garbageModel.path)
        model.useLLM = true
        await model.open(url)
        await model.anonymize()

        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(model.aiActive, "AI reported active although the engine failed to load")
        XCTAssertNotNil(model.aiWarning, "the AI failure must surface, not be swallowed")
        XCTAssertFalse(model.entities.isEmpty, "deterministic detection still contributes")
    }

    /// A truncated (not fully scanned) AI pass must not present itself as a
    /// complete AI pass: salvaged spans are kept, but aiActive turns off and a
    /// warning explains that unscanned text may still contain names.
    func testIncompleteAIScanSurfacesWarning() async throws {
        let url = workDir.appendingPathComponent("d.txt")
        try Data("Acme".utf8).write(to: url)
        let dummyModel = workDir.appendingPathComponent("dummy.gguf")
        try Data("placeholder".utf8).write(to: dummyModel)

        struct AlwaysTruncating: TextCompleter {
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
                // An unterminated entities array: parseDetailed flags truncation.
                return #"{"entities":[{"value":"Acm"#
            }
        }
        ReviewModel.llmExtractorFactoryForTesting = { _, _ in
            LLMExtractor(completer: AlwaysTruncating())
        }
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let model = ReviewModel(modelPath: dummyModel.path)
        model.useLLM = true
        await model.open(url)
        await model.anonymize()

        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(model.aiActive, "an incomplete scan is not a complete AI pass")
        XCTAssertNotNil(model.aiWarning)
    }

    /// The other way a pass can be incomplete: every segment was scanned, but a
    /// value the model reported anchors nowhere in the document, so it cannot be
    /// redacted. That is not a complete AI pass either, and the warning must say
    /// what actually went wrong rather than blaming truncation.
    func testUnanchorableValueSurfacesWarningAndIsNotACompleteAIPass() async throws {
        let url = workDir.appendingPathComponent("unanchored.txt")
        try Data("The seller is Acme Corp.".utf8).write(to: url)
        let dummyModel = workDir.appendingPathComponent("dummy-unanchored.gguf")
        try Data("placeholder".utf8).write(to: dummyModel)

        struct ReportsUnanchorableValue: TextCompleter {
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
                // Well-formed and complete: nothing is truncated. The company is
                // really in the document, but the reported form has reflowed
                // whitespace, so it cannot be anchored and would survive.
                return #"{"entities":[{"value":"Acme  Corp","type":"COMPANY"}],"redacted_text":""}"#
            }
        }
        ReviewModel.llmExtractorFactoryForTesting = { _, _ in
            LLMExtractor(completer: ReportsUnanchorableValue())
        }
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let model = ReviewModel(modelPath: dummyModel.path)
        model.useLLM = true
        await model.open(url)
        await model.anonymize()

        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(
            model.aiActive,
            "a pass that left a detected value unredactable is not a complete AI pass"
        )
        let warning = try XCTUnwrap(model.aiWarning)
        XCTAssertTrue(
            warning.lowercased().contains("locate"),
            "the warning must describe the anchoring failure, not truncation: \(warning)"
        )
        XCTAssertFalse(
            warning.lowercased().contains("scan"),
            "a truncation message here would misdiagnose the failure: \(warning)"
        )
    }

    // MARK: - Stop button (cancellation)

    /// A completer that blocks until the run's cancel token fires, then keeps
    /// throwing, simulating a long generation the user interrupts.
    private final class BlockingUntilCancelled: TextCompleter, CancelAwareCompleter {
        var cancelToken: ExtractionCancelToken?
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            while cancelToken?.isCancelled != true {
                Thread.sleep(forTimeInterval: 0.01)
            }
            throw LLMEngine.LLMError.cancelled
        }
    }

    /// Stopping mid-anonymize must restore the prior status, keep the document
    /// loaded, and present NO detection outcome (no entities, no AI warning):
    /// a partial pass shown as complete would be trusted as one.
    func testCancelAnonymizeRestoresPriorStateWithoutResults() async throws {
        let url = workDir.appendingPathComponent("stop.txt")
        try Data("Contact \(Self.email) and Jordan Lee now.".utf8).write(to: url)
        let dummyModel = workDir.appendingPathComponent("dummy2.gguf")
        try Data("placeholder".utf8).write(to: dummyModel)

        ReviewModel.llmExtractorFactoryForTesting = { _, cancel in
            LLMExtractor(completer: BlockingUntilCancelled(), cancelToken: cancel)
        }
        defer { ReviewModel.llmExtractorFactoryForTesting = nil }

        let model = ReviewModel(modelPath: dummyModel.path)
        model.useLLM = true
        await model.open(url)
        XCTAssertEqual(model.status, .imported)

        let run = Task { await model.anonymize() }
        // Wait until the pass has actually entered detection, then stop it.
        var waited = 0
        while model.status != .detecting && waited < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            waited += 1
        }
        XCTAssertEqual(model.status, .detecting, "the pass never started")
        model.cancelAnonymize()
        await run.value

        XCTAssertEqual(model.status, .imported, "cancel must restore the pre-anonymize status")
        XCTAssertTrue(model.entities.isEmpty, "no partial detection may be presented")
        XCTAssertNil(model.aiWarning, "a user stop is not an AI failure")
        XCTAssertEqual(model.progress, 0)
        XCTAssertNil(model.etaText)
        XCTAssertTrue(model.documentText.contains("Jordan Lee"), "document stays loaded")
    }

    // MARK: - Export collision guard

    /// A second export into the same folder must not overwrite the first one:
    /// the prior .ldamap may be the only key to restore an already-shared
    /// document. The export auto-suffixes instead.
    func testExportDoesNotOverwriteExistingExport() async throws {
        let url = workDir.appendingPathComponent("e.txt")
        try Data("Contact \(Self.email) now.".utf8).write(to: url)
        let outDir = workDir.appendingPathComponent("exports", isDirectory: true)

        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        await model.open(url)
        await model.anonymize()

        let first = try await model.export(
            to: outDir, passphrase: "pw", createdAtISO8601: Self.createdAt
        )
        let second = try await model.export(
            to: outDir, passphrase: "pw", createdAtISO8601: Self.createdAt
        )

        XCTAssertNotEqual(first.redactedURL, second.redactedURL, "second export overwrote the first")
        XCTAssertNotEqual(first.mappingURL, second.mappingURL, "second export clobbered the first mapping")
        for fileURL in [first.redactedURL, first.mappingURL, second.redactedURL, second.mappingURL] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fileURL.path),
                "missing \(fileURL.lastPathComponent)"
            )
        }
    }

    // MARK: - Embedded media warning

    /// Exporting a DOCX that embeds media must report the count so the UI can
    /// warn that signature images were not scanned.
    func testExportReportsEmbeddedMediaCount() async throws {
        let docx = workDir.appendingPathComponent("media.docx")
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Default Extension="png" ContentType="image/png"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">Contact \(Self.email) today.</w:t></w:r></w:p></w:body>
        </w:document>
        """
        try DocxZip.writeArchive(
            parts: [
                ("[Content_Types].xml", Data(contentTypes.utf8)),
                ("_rels/.rels", Data(rels.utf8)),
                ("word/document.xml", Data(document.utf8)),
                ("word/media/image1.png", Data([0x89, 0x50, 0x4E, 0x47]))
            ],
            to: docx
        )

        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        await model.open(docx)
        await model.anonymize()

        let result = try await model.export(
            to: workDir.appendingPathComponent("media-out", isDirectory: true),
            passphrase: "pw",
            createdAtISO8601: Self.createdAt
        )
        XCTAssertEqual(result.embeddedMediaCount, 1)
    }

    // MARK: - Keyboard review loop (groups, selection, toggling)

    /// Build a model whose entities cover two types with a repeated value, set
    /// directly so the tests need no detection pass.
    private func makeGroupedModel() -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        let text = "Acme Corp and John Smith met Acme Corp at jane@x.example."
        model.documentText = text
        func span(_ surface: String, _ type: EntityType, occurrence: Int = 0) -> Span {
            let ns = text as NSString
            var search = NSRange(location: 0, length: ns.length)
            var found = NSRange(location: NSNotFound, length: 0)
            for _ in 0...occurrence {
                found = ns.range(of: surface, options: [], range: search)
                precondition(found.location != NSNotFound)
                search = NSRange(
                    location: found.location + found.length,
                    length: ns.length - found.location - found.length
                )
            }
            return Span(
                start: found.location, end: found.location + found.length,
                type: type, text: surface, source: .llm, confidence: 0.9, priority: 30
            )
        }
        model.entities = [
            ReviewEntity(span: span("Acme Corp", .company, occurrence: 0), accepted: true),
            ReviewEntity(span: span("Acme Corp", .company, occurrence: 1), accepted: true),
            ReviewEntity(span: span("John Smith", .person), accepted: true),
            ReviewEntity(span: span("jane@x.example", .email), accepted: true)
        ]
        return model
    }

    func testGroupsFollowTypeOrderThenFirstAppearance() {
        let model = makeGroupedModel()
        let groups = model.entityGroups

        // PERSON before COMPANY before EMAIL per the sidebar's type order, and
        // the two Acme occurrences collapse into one group of two.
        XCTAssertEqual(groups.map { $0.value }, ["John Smith", "Acme Corp", "jane@x.example"])
        XCTAssertEqual(groups[1].occurrences, 2)
    }

    func testSelectNextAndPreviousGroupWrap() {
        let model = makeGroupedModel()
        XCTAssertNil(model.selectedGroupID)

        model.selectNextGroup()
        XCTAssertEqual(model.selectedGroupID, model.entityGroups[0].id, "first selection lands on the first group")
        model.selectNextGroup()
        model.selectNextGroup()
        XCTAssertEqual(model.selectedGroupID, model.entityGroups[2].id)
        model.selectNextGroup()
        XCTAssertEqual(model.selectedGroupID, model.entityGroups[0].id, "next wraps to the first group")

        model.selectPreviousGroup()
        XCTAssertEqual(model.selectedGroupID, model.entityGroups[2].id, "previous wraps to the last group")
    }

    func testToggleSelectedGroupFlipsEveryOccurrence() {
        let model = makeGroupedModel()
        model.selectNextGroup()
        model.selectNextGroup()  // the Acme Corp group (2 occurrences)
        let acmeIDs = model.entityGroups[1].ids

        model.toggleSelectedGroup()
        for entity in model.entities where acmeIDs.contains(entity.id) {
            XCTAssertFalse(entity.accepted, "toggle must reject every occurrence")
        }
        // Unrelated entities stay untouched.
        XCTAssertTrue(model.entities.first { $0.span.type == .person }!.accepted)

        model.toggleSelectedGroup()
        for entity in model.entities where acmeIDs.contains(entity.id) {
            XCTAssertTrue(entity.accepted, "toggle back must accept every occurrence")
        }
    }

    func testBatchSelectionAppliesOneDecisionToSeveralGroups() {
        let model = makeGroupedModel()
        let person = model.groups(of: .person)[0]
        let company = model.groups(of: .company)[0]
        let email = model.groups(of: .email)[0]
        model.selectedGroupIDs = [person.id, company.id]

        model.setSelectedGroupsAccepted(false)

        for entity in model.entities where person.ids.contains(entity.id) || company.ids.contains(entity.id) {
            XCTAssertFalse(entity.accepted)
        }
        XCTAssertTrue(
            model.entities.first(where: { email.ids.contains($0.id) })!.accepted,
            "a batch decision must not spill into an unselected group"
        )

        model.setSelectedGroupsAccepted(true)
        XCTAssertTrue(model.entities.allSatisfy(\.accepted))
    }

    func testKeyboardToggleAppliesToEverySelectedGroupAndKeepsTheSelection() {
        let model = makeGroupedModel()
        let selected = Set(model.entityGroups.prefix(2).map(\.id))
        model.selectedGroupIDs = selected

        model.toggleSelectedGroup()

        XCTAssertEqual(model.selectedGroupIDs, selected, "the user can immediately reverse a batch action")
        let selectedEntityIDs = Set(
            model.entityGroups
                .filter { selected.contains($0.id) }
                .flatMap(\.ids)
        )
        for entity in model.entities where selectedEntityIDs.contains(entity.id) {
            XCTAssertFalse(entity.accepted)
        }
    }

    func testToggleMixedGroupRejectsFirst() {
        // A group with mixed accept states reads as accepted (anyAccepted), so
        // the first toggle must move the whole group to rejected.
        let model = makeGroupedModel()
        let acme = model.entityGroups[1]
        let oneID = acme.ids.first!
        model.setAccepted(oneID, false)

        model.selectedGroupID = acme.id
        model.toggleSelectedGroup()
        for entity in model.entities where acme.ids.contains(entity.id) {
            XCTAssertFalse(entity.accepted)
        }
    }

    func testSetAcceptedByTypeAppliesToAllGroupsOfThatType() {
        let model = makeGroupedModel()
        model.setAccepted(type: .company, false)

        for entity in model.entities {
            if entity.span.type == .company {
                XCTAssertFalse(entity.accepted)
            } else {
                XCTAssertTrue(entity.accepted, "other types must stay untouched")
            }
        }
    }

    func testOpeningADocumentClearsGroupSelection() async throws {
        let model = makeGroupedModel()
        model.selectedGroupIDs = Set(model.entityGroups.prefix(2).map(\.id))
        XCTAssertEqual(model.selectedGroupIDs.count, 2)

        let url = workDir.appendingPathComponent("clear.txt")
        try Data("Fresh text.".utf8).write(to: url)
        await model.open(url)

        XCTAssertTrue(model.selectedGroupIDs.isEmpty, "selection must not survive into a new document")
    }

    func testSuccessfulRescanClearsThePreviousResultSelection() async {
        let model = makeGroupedModel()
        model.useLLM = false
        model.status = .ready
        model.selectedGroupIDs = Set(model.entityGroups.prefix(2).map(\.id))
        XCTAssertEqual(model.selectedGroupIDs.count, 2)

        await model.anonymize()

        XCTAssertEqual(model.status, .ready)
        XCTAssertFalse(model.entities.isEmpty, "the rescan fixture still produces a finding")
        XCTAssertTrue(
            model.selectedGroupIDs.isEmpty,
            "a fresh result set must not inherit selections from the previous scan"
        )
    }

    // MARK: - Failure recovery (audit F2)
    //
    // The audit's F2 premise was that a failed pass is a dead end. Tracing the
    // state machine shows the picture is narrower than that: `.failed` is set
    // in exactly ONE place, open(_:)'s catch, so it always means an IMPORT
    // failure with no text. anonymize() cannot fail at all (it ends at .ready;
    // an LLM problem becomes aiWarning). The recovery for an import failure is
    // re-opening the file, which the document pane already offers prominently
    // and which File > Open (Cmd+O) now reaches from the keyboard.
    //
    // An earlier attempt at F2 added a "Try again" retry gated on
    // `.failed` plus non-empty text, and two tests asserting it. Both tests
    // passed while proving nothing, because they set a state combination the
    // app cannot produce. The tests below assert only reachable states.

    func testDetectionNeverProducesAFailedStatus() {
        // The load-bearing fact behind the rest of this section. If detection
        // ever gains a hard failure state, this test fails and whoever adds it
        // has to revisit the recovery affordances rather than discovering the
        // gap in production.
        let producers = Self.failedStatusProducerCount()
        XCTAssertEqual(
            producers, 1,
            "ReviewModel should set .failed in exactly one place (open's catch). "
                + "Found \(producers). If detection now fails too, the failure "
                + "banner needs a retry path and canAnonymize needs revisiting."
        )
    }

    func testAFailedImportIsNotScannable() {
        // An import failure leaves no text. Re-running detection over nothing
        // would report a clean scan of an empty document.
        let model = ReviewModel(modelPath: nil)
        model.status = .failed("The file could not be read.")

        XCTAssertFalse(model.canAnonymize)
    }

    func testRequestAnonymizeStaysInertAfterAFailedImport() {
        let model = ReviewModel(modelPath: nil)
        model.status = .failed("unreadable")
        let tokenBefore = model.anonymizeRequestToken

        model.requestAnonymize()

        XCTAssertEqual(
            model.anonymizeRequestToken, tokenBefore,
            "an empty document must not be scannable; re-opening is the recovery"
        )
    }

    func testAFailedImportClearsAnyPreviousDocumentText() async throws {
        // The attribution guard. open(_:) sets the NEW sourceURL before it
        // imports, so if a failed import left the PREVIOUS document's text in
        // place, the model would describe document A's contents while every
        // label (window title, tray row, export name, mapping sourceFile) took
        // document B's name. Production builds a fresh model per document, but
        // the invariant is enforced rather than assumed.
        let model = ReviewModel(modelPath: nil)
        let good = workDir.appendingPathComponent("good.txt")
        try Data("Contact jane.doe@example.com about the matter.".utf8).write(to: good)
        await model.open(good)
        XCTAssertFalse(model.documentText.isEmpty, "precondition: the first import succeeded")

        // Now re-open the same model on a file that cannot be imported.
        let missing = workDir.appendingPathComponent("does-not-exist.txt")
        await model.open(missing)

        guard case .failed = model.status else {
            return XCTFail("expected a failed import, got \(model.status)")
        }
        XCTAssertTrue(
            model.documentText.isEmpty,
            "a failed import must not leave the previous document's text behind"
        )
        XCTAssertFalse(
            model.canAnonymize,
            "and it must not become scannable via retained text"
        )
    }

    /// Count the `status = .failed` assignments in ReviewModel's own source.
    ///
    /// A source scan rather than a behavioral probe, because the claim being
    /// guarded is about the SHAPE of the state machine: that no second failure
    /// producer has been added. No behavioral test can observe the absence of a
    /// transition that does not exist.
    private static func failedStatusProducerCount() -> Int {
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()   // LDACoreTests
                .deletingLastPathComponent()   // Tests
                .deletingLastPathComponent()   // LDACore package root
                .appendingPathComponent("Sources/LDAUI/ReviewModel.swift")
        ]
        guard let source = candidates.lazy.compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first else {
            // Cannot locate the source (a packaging layout change): report the
            // expected value rather than failing for an unrelated reason.
            return 1
        }
        return source.components(separatedBy: "status = .failed").count - 1
    }

}
