//
//  FillLiveModelTests.swift
//  LDACoreTests
//
//  Gated integration test for the fill-from-profile pipeline using a real
//  on-device GGUF model. Skipped unless the model is present at one of:
//    1. The path in the LDA_MODEL_PATH environment variable.
//    2. ~/Developer/lda-models/lda-v2-Q4_K_M.gguf (default packaging path).
//
//  Run with:
//    LDA_MODEL_PATH=/path/to/model.gguf swift test --filter FillLiveModelTests
//
//  The test covers two things:
//    1. extractProfile over a synthetic certificate text surfaces at least
//       companyName and the extracted snippet is grounded (snippetVerified).
//    2. planFill on a fixture .docx containing "[Company Name]" proposes a
//       fill; confirming all proposed+valued blanks and calling applyFill
//       produces a filled document that contains the extracted company name.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class FillLiveModelTests: XCTestCase {

    // MARK: - Constants

    private static let createdAt = "2026-06-11T00:00:00Z"

    // MARK: - Hermetic working directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FillLiveModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Guard helper (mirrors LDAServiceLLMTests.resolveModelPath)

    /// Resolve the GGUF model path from the environment or the default packaging
    /// location. Returns nil when neither is present.
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

    // MARK: - Fixture helpers

    /// Write a certificate-like plain-text source file for extractProfile.
    /// The text carries companyName, companyNumber, incorporationDate, and
    /// registeredOffice in realistic certificate phrasing.
    private func writeCertificateText() throws -> URL {
        let text = """
        CERTIFICATE OF INCORPORATION

        This is to certify that Meridian Pacific Holdings Limited (the "Company")
        was duly incorporated under the laws of the British Virgin Islands.

        Company Number: BC-20240811

        Date of Incorporation: 11 August 2024

        Registered Office:
        Meridian Trust Company, 3rd Floor, Harbour Centre,
        Road Town, Tortola, British Virgin Islands

        The Company is authorized to carry on any lawful business activity.

        ISSUED by the Registry of Corporate Affairs
        """
        let url = workDir.appendingPathComponent("certificate.txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Write a minimal fixture .docx that contains the "[Company Name]" blank.
    /// Replicates the inline DocxZip builder used in FillServiceTests.
    private func writeBlankDocx(companyPlaceholder: String = "[Company Name]") throws -> URL {
        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body><w:p><w:r><w:t xml:space="preserve">This agreement is entered into by \(companyPlaceholder), a company incorporated under applicable law.</w:t></w:r></w:p></w:body>
        </w:document>
        """
        let url = workDir.appendingPathComponent("template-\(UUID().uuidString).docx")
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypesXML.utf8)),
            ("_rels/.rels", Data(relsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ]
        try DocxZip.writeArchive(parts: parts, to: url)
        return url
    }

    // MARK: - Live model test

    /// Gated integration test. Requires a GGUF model at LDA_MODEL_PATH or at
    /// the default packaging location; skipped cleanly otherwise.
    ///
    /// Part 1: extractProfile over the certificate text must surface at least
    /// companyName AND that field must be grounded (snippetVerified == true).
    ///
    /// Part 2: planFill on a fixture docx with "[Company Name]" must produce at
    /// least one .proposed blank; confirming proposed+valued blanks and calling
    /// applyFill must produce a filled document that contains the extracted
    /// company name.
    func testExtractProfileAndFillWithRealModel() throws {
        guard let modelPath = resolveModelPath() else {
            throw XCTSkip(
                "GGUF model not present; set LDA_MODEL_PATH or place the model at "
                    + "~/Developer/lda-models/lda-v2-Q4_K_M.gguf"
            )
        }

        // MARK: Part 1 - extractProfile

        let certURL = try writeCertificateText()

        let extracted = try LDAService.extractProfile(
            sources: [certURL],
            label: "MeridianLive",
            modelPath: modelPath,
            createdAtISO8601: Self.createdAt
        )

        let profile = extracted.profile

        // The model must extract at least companyName.
        let companyNameField = profile.fields.first { $0.key == .companyName }
        XCTAssertNotNil(
            companyNameField,
            "extractProfile with a real model must surface companyName; got fields: "
                + profile.fields.map { $0.key.rawKey }.joined(separator: ", ")
        )

        // The extracted companyName snippet must be grounded in the source text.
        if let field = companyNameField {
            XCTAssertTrue(
                field.snippetVerified,
                "companyName snippet must be grounded (snippetVerified=true); "
                    + "value=\(field.value), snippet=\(field.sourceSnippet)"
            )
            // The profile is now in hand; use it for Part 2.
            try runFillPart(profile: profile, extractedCompanyName: field.value, modelPath: modelPath)
        }
    }

    // MARK: - Part 2 helper (separate function to keep line count manageable)

    private func runFillPart(
        profile: ClientPortfolio,
        extractedCompanyName: String,
        modelPath: String
    ) throws {
        let docxURL = try writeBlankDocx()
        let outputDir = workDir.appendingPathComponent("fill-out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // planFill with the real model path; the synonym pass should hit
        // "Company Name" directly so a model call may not be needed, but the
        // real modelPath is supplied to exercise the full code path.
        var plan = try LDAService.planFill(
            target: docxURL,
            profile: profile,
            modelPath: modelPath
        )

        XCTAssertFalse(
            plan.blanks.isEmpty,
            "planFill must detect at least one blank in a document containing '[Company Name]'"
        )

        // Promote proposed+valued blanks to confirmed.
        plan.blanks = plan.blanks.map { blank in
            guard blank.status == .proposed,
                  let v = blank.proposedValue, !v.isEmpty else { return blank }
            return Blank(
                id: blank.id,
                location: blank.location,
                label: blank.label,
                context: blank.context,
                proposedFieldID: blank.proposedFieldID,
                proposedValue: blank.proposedValue,
                status: .confirmed
            )
        }

        let confirmedCount = plan.blanks.filter { $0.status == .confirmed }.count
        XCTAssertGreaterThanOrEqual(
            confirmedCount, 1,
            "at least one blank must be confirmed after promoting proposed+valued blanks"
        )

        // applyFill.
        let report = try LDAService.applyFill(
            plan: plan,
            target: docxURL,
            profile: profile,
            outputDir: outputDir
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: report.outputURL.path),
            "applyFill must produce an output file"
        )

        // The filled document must contain the extracted company name.
        let filled = try DocxImporter().importDocument(report.outputURL)
        XCTAssertTrue(
            filled.text.contains(extractedCompanyName),
            "filled document must contain the extracted company name '\(extractedCompanyName)'; "
                + "got: \(filled.text.prefix(300))"
        )

        // The blank placeholder must have been replaced.
        XCTAssertFalse(
            filled.text.contains("[Company Name]"),
            "the '[Company Name]' placeholder must not remain in the filled document"
        )
    }
}
