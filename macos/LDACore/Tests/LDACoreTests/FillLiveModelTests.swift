//
//  FillLiveModelTests.swift
//  LDACoreTests
//
//  Gated integration test for the fill-from-profile pipeline using a real
//  on-device GGUF model. LiveModelTestSupport resolves the model path and
//  skips cleanly when the model is absent, and holds a machine-wide lock while
//  the model is resident so a concurrent test process cannot starve the GPU.
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

    /// Write a realistic identity-letter plain-text source file for extractProfile
    /// with kind .individual. The text carries clientName, dateOfBirth, passportNumber,
    /// nationality, and residentialAddress in authentic letter phrasing.
    private func writeIdentityLetterText() throws -> URL {
        let text = """
        IDENTITY CONFIRMATION LETTER

        To Whom It May Concern:

        This letter is to confirm the identity of the individual named below,
        who has been a client of this firm since 2019.

        Full Name: Jonathan Andrew Whitmore
        Date of Birth: 14 March 1982
        Nationality: British
        Passport Number: BC793241
        Residential Address: 47 Kensington Gardens Square, London W2 4BJ, United Kingdom

        The above information has been verified against the original passport document
        presented to our office on 3 June 2026.

        We confirm that the passport was valid and unexpired at the time of presentation.

        Yours faithfully,
        Pemberton & Associates LLP
        """
        let url = workDir.appendingPathComponent("identity-letter.txt")
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Write a minimal fixture .docx that contains "[Full Name]" and
    /// "[Passport Number]" blanks, matching the individual-kind synonyms.
    private func writeIndividualBlankDocx() throws -> URL {
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
        <w:body>\
        <w:p><w:r><w:t xml:space="preserve">Client name: [Full Name]</w:t></w:r></w:p>\
        <w:p><w:r><w:t xml:space="preserve">Passport: [Passport Number]</w:t></w:r></w:p>\
        </w:body>
        </w:document>
        """
        let url = workDir.appendingPathComponent("individual-template-\(UUID().uuidString).docx")
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
        // withLiveModel holds a machine-wide lock while the model is resident:
        // a second test process loading it at the same time exhausts unified
        // memory, and llama.cpp answers with garbage rather than throwing.
        try LiveModelTestSupport.withLiveModel { modelPath in
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
    }

    // MARK: - Individual-kind live model test

    /// Gated integration test for the .individual portfolio kind. Requires a GGUF
    /// model at LDA_MODEL_PATH or at the default packaging location; skipped
    /// cleanly otherwise.
    ///
    /// Part 1: extractProfile with kind .individual over an identity-letter text
    /// must surface at least clientName OR passportNumber AND the extracted field
    /// must be grounded (snippetVerified == true).
    ///
    /// Part 2: planFill on a fixture .docx with "[Full Name]" and "[Passport Number]"
    /// must propose at least one fill; confirming proposed-valued blanks and calling
    /// applyFill must produce a filled document that contains the extracted value.
    func testIndividualKindLiveExtractionAndFill() throws {
        // withLiveModel holds a machine-wide lock while the model is resident:
        // a second test process loading it at the same time exhausts unified
        // memory, and llama.cpp answers with garbage rather than throwing.
        try LiveModelTestSupport.withLiveModel { modelPath in
            // MARK: Part 1 - extractProfile (kind .individual)

            let letterURL = try writeIdentityLetterText()

            let extracted = try LDAService.extractProfile(
                sources: [letterURL],
                label: "JohnDoeLive",
                kind: .individual,
                modelPath: modelPath,
                createdAtISO8601: Self.createdAt
            )

            let profile = extracted.profile

            // The model must extract at least one of: clientName or passportNumber.
            let clientNameField   = profile.fields.first { $0.key == .clientName }
            let passportField     = profile.fields.first { $0.key == .passportNumber }

            let surfacedSomething = clientNameField != nil || passportField != nil
            XCTAssertTrue(
                surfacedSomething,
                "extractProfile with kind=.individual must surface clientName or passportNumber; "
                    + "got fields: "
                    + profile.fields.map { $0.key.rawKey }.joined(separator: ", ")
            )

            // The first surfaced field must be grounded (snippetVerified == true).
            let anchorField = clientNameField ?? passportField
            if let anchor = anchorField {
                XCTAssertTrue(
                    anchor.snippetVerified,
                    "\(anchor.key.rawKey) snippet must be grounded (snippetVerified=true); "
                        + "value=\(anchor.value), snippet=\(anchor.sourceSnippet)"
                )
                // Part 2 uses whichever field surfaced first.
                try runIndividualFillPart(
                    profile: profile,
                    anchorField: anchor,
                    modelPath: modelPath
                )
            }
        }
    }

    // MARK: - Individual Part 2 helper

    /// Verify that the fill pipeline works end-to-end for the .individual kind.
    ///
    /// The fixture .docx contains both "[Full Name]" and "[Passport Number]"
    /// placeholders. The synonym matcher should hit at least one of them
    /// (clientName <-> "Full Name", passportNumber <-> "Passport Number").
    private func runIndividualFillPart(
        profile: ClientPortfolio,
        anchorField: ProfileField,
        modelPath: String
    ) throws {
        let docxURL = try writeIndividualBlankDocx()
        let outputDir = workDir.appendingPathComponent("individual-fill-out", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // planFill: synonym matching should hit "Full Name" and "Passport Number".
        var plan = try LDAService.planFill(
            target: docxURL,
            profile: profile,
            modelPath: modelPath
        )

        XCTAssertFalse(
            plan.blanks.isEmpty,
            "planFill must detect at least one blank in a document containing "
                + "'[Full Name]' and '[Passport Number]'"
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

        // The filled document must contain the anchor field value.
        let filled = try DocxImporter().importDocument(report.outputURL)
        XCTAssertTrue(
            filled.text.contains(anchorField.value),
            "filled document must contain the extracted \(anchorField.key.rawKey) "
                + "'\(anchorField.value)'; got: \(filled.text.prefix(300))"
        )
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
