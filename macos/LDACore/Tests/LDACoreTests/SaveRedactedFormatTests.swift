//
//  SaveRedactedFormatTests.swift
//  LDACoreTests
//
//  The output format in the app: Save Redacted (ReviewModel.export) writes
//  Markdown or the original format through the shared writer, rereads and
//  checks the source only when the format rebuilds from it, never replaces
//  a file already in the folder, and keeps the boxed PDF or image beside its
//  restorable text. The two remembered choices (AISettings), the sentences
//  around them (RedactedOutputFormatPresentation) and the batch window's
//  options read the same values.
//
//  Deterministic detection only, except the image tests, which run Vision
//  OCR on planted fixtures. No model, no Keychain, no shared defaults.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import ImageIO
import PDFKit
import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class SaveRedactedFormatTests: XCTestCase {

    private var workDir: URL!

    private static let email = "client-contact@example.invalid"
    private static let phone = "13812345678"
    private static let passphrase = "save-format-passphrase"
    private static let createdAt = "2026-11-11T00:00:00Z"

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveRedactedFormatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A Word document with the email in its body and the phone in its header.
    private func writeAgreement(named name: String = "agreement.docx", extra: String? = nil) throws -> URL {
        var body = DocxTestPackage.paragraph(DocxTestPackage.run("Write to \(Self.email) about the lease."))
        if let extra { body += DocxTestPackage.paragraph(DocxTestPackage.run(extra)) }
        return try DocxTestPackage.write(
            body: body + DocxTestPackage.sectionWithHeaderAndFooter,
            extraParts: [
                ("word/header1.xml", DocxTestPackage.wordPart(
                    rootTag: "hdr",
                    body: DocxTestPackage.paragraph(DocxTestPackage.run("Call \(Self.phone)"))
                )),
                ("word/footer1.xml", DocxTestPackage.wordPart(
                    rootTag: "ftr",
                    body: DocxTestPackage.paragraph(DocxTestPackage.run("Page 1"))
                ))
            ],
            to: workDir.appendingPathComponent(name)
        )
    }

    private func writeLeasePDF(lines: [String]? = nil) throws -> URL {
        try OutputFormatFixtures.writePDF(
            [.init(size: OutputFormatFixtures.letter, lines: lines ?? ["Tenant email \(Self.email)", "Phone \(Self.phone)"])],
            metadataValue: Self.email,
            to: workDir.appendingPathComponent("lease.pdf")
        )
    }

    private func scannedModel(for source: URL) async throws -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        await model.open(source)
        await model.anonymize()
        XCTAssertTrue(model.exportAvailability.isAvailable, "fixture: the scan finished")
        XCTAssertFalse(model.entities.isEmpty, "fixture: something was found")
        return model
    }

    private func export(
        _ model: ReviewModel,
        format: RedactedOutputFormat,
        into folder: String = "out"
    ) async throws -> ExportResult {
        try await model.export(
            to: workDir.appendingPathComponent(folder, isDirectory: true),
            passphrase: Self.passphrase,
            createdAtISO8601: Self.createdAt,
            format: format
        )
    }

    private func files(in folder: String = "out") -> [String] {
        let url = workDir.appendingPathComponent(folder, isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: - Word

    func testMarkdownWritesTheBodyAsOneMarkdownFileAndCountsOnlyTheBody() async throws {
        let source = try writeAgreement()
        let model = try await scannedModel(for: source)

        let result = try await export(model, format: .markdown)

        XCTAssertEqual(result.redactedURL.lastPathComponent, "agreement_redacted.md")
        XCTAssertNil(result.redactedImageURL)
        XCTAssertEqual(result.supplementaryEntityCount, 0, "headers are not part of the Markdown")
        XCTAssertEqual(result.entityCount, model.redactedCount)
        XCTAssertEqual(result.embeddedMediaCount, 0)
        XCTAssertEqual(files(), ["agreement_redacted.ldamap", "agreement_redacted.md"])

        let markdown = try String(contentsOf: result.redactedURL, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix(MarkdownHandoffWriter.tokenStylePreamble), markdown)
        XCTAssertFalse(markdown.contains(Self.email), markdown)
        XCTAssertFalse(markdown.contains(Self.phone), markdown)

        let restored = workDir.appendingPathComponent("restored.md")
        _ = try LDAService.restore(
            editedRedacted: result.redactedURL,
            mapping: try XCTUnwrap(result.mappingURL),
            protection: .passphrase(Self.passphrase),
            output: restored
        )
        XCTAssertEqual(
            try String(contentsOf: restored, encoding: .utf8),
            MarkdownHandoffWriter.tokenStylePreamble + "\n\n" + model.documentText
        )
    }

    func testTheOriginalFormatKeepsTheWordDocumentAndItsHeader() async throws {
        let source = try writeAgreement()
        let model = try await scannedModel(for: source)

        let result = try await export(model, format: .original)

        XCTAssertEqual(result.redactedURL.lastPathComponent, "agreement_redacted.docx")
        XCTAssertNil(result.redactedImageURL)
        XCTAssertGreaterThan(result.supplementaryEntityCount, 0, "the header's phone is redacted too")
        for member in try DocxTestPackage.allMembers(in: result.redactedURL) {
            XCTAssertFalse(OutputFormatFixtures.contains(member.data, Self.email), member.path)
            XCTAssertFalse(OutputFormatFixtures.contains(member.data, Self.phone), member.path)
        }
    }

    func testAMarkdownExportDoesNotRereadTheWordFileButTheOriginalFormatDoes() async throws {
        let source = try writeAgreement()
        let markdownModel = try await scannedModel(for: source)
        let originalModel = try await scannedModel(for: source)
        _ = try writeAgreement(extra: "Unreviewed contact unreviewed@example.invalid")

        // Markdown is written from the reviewed text alone.
        let markdown = try await export(markdownModel, format: .markdown, into: "markdown")
        XCTAssertEqual(markdown.redactedURL.pathExtension, "md")

        // The original format rebuilds from the file, so a changed file is refused.
        do {
            _ = try await export(originalModel, format: .original, into: "original")
            XCTFail("the original format must refuse a source that changed after the scan")
        } catch {
            XCTAssertTrue(error is SourceChangedSinceScanError, "unexpected error: \(error)")
        }
        XCTAssertEqual(files(in: "original"), [])
    }

    func testExportReadsTheSourceOnlyWhenTheFormatRebuildsFromIt() {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
        for name in ["a.docx", "a.pdf", "a.png", "a.jpg"] {
            XCTAssertTrue(ReviewModel.exportReadsSource(url(name), format: .original), name)
            XCTAssertFalse(ReviewModel.exportReadsSource(url(name), format: .markdown), name)
        }
        XCTAssertFalse(ReviewModel.exportReadsSource(url("a.txt"), format: .original))
        XCTAssertFalse(ReviewModel.exportReadsSource(url("a.md"), format: .original))
    }

    // MARK: - PDF

    func testTheOriginalFormatWritesTheBoxedPDFBesideItsRestorableText() async throws {
        let source = try writeLeasePDF()
        let model = try await scannedModel(for: source)

        let result = try await export(model, format: .original)

        XCTAssertEqual(result.redactedURL.lastPathComponent, "lease_redacted.txt", "the text is what restores")
        XCTAssertEqual(result.redactedImageURL?.lastPathComponent, "lease_redacted.pdf")
        XCTAssertEqual(result.unboxedTokenCount, 0)
        XCTAssertEqual(files(), ["lease_redacted.ldamap", "lease_redacted.pdf", "lease_redacted.txt"])

        let pdf = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(result.redactedImageURL)))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertEqual(PdfPageGeometry.displaySize(of: try XCTUnwrap(pdf.page(at: 0))), OutputFormatFixtures.letter)
        let extracted = pdf.string ?? ""
        XCTAssertFalse(extracted.contains(Self.email))
        XCTAssertFalse(extracted.contains(Self.phone))
        XCTAssertTrue(pdf.findString(Self.email, withOptions: []).isEmpty)
        let text = try String(contentsOf: result.redactedURL, encoding: .utf8)
        XCTAssertFalse(text.contains(Self.email), text)
    }

    func testAPDFChangedAfterTheScanIsRefusedInTheOriginalFormat() async throws {
        let source = try writeLeasePDF()
        let model = try await scannedModel(for: source)
        _ = try writeLeasePDF(lines: ["Tenant email \(Self.email)", "New contact added@example.invalid"])

        do {
            _ = try await export(model, format: .original)
            XCTFail("a PDF rebuilt from a changed file must be refused")
        } catch {
            XCTAssertTrue(error is SourceChangedSinceScanError, "unexpected error: \(error)")
        }
        XCTAssertEqual(files(), [])
    }

    func testAnExportNeverReplacesAFileTheFormatWouldWrite() async throws {
        let source = try writeLeasePDF()
        let model = try await scannedModel(for: source)
        let folder = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Only the text companion's name is taken.
        try Data("an earlier file".utf8).write(to: folder.appendingPathComponent("lease_redacted.txt"))
        try Data("an earlier note".utf8).write(to: folder.appendingPathComponent("lease_redacted.md"))

        let original = try await export(model, format: .original)
        XCTAssertEqual(original.redactedURL.lastPathComponent, "lease_redacted_2.txt")
        XCTAssertEqual(original.redactedImageURL?.lastPathComponent, "lease_redacted_2.pdf")

        let markdown = try await export(model, format: .markdown)
        XCTAssertEqual(markdown.redactedURL.lastPathComponent, "lease_redacted_3.md", "_2 holds a mapping now")
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("lease_redacted.txt"), encoding: .utf8),
            "an earlier file"
        )
        XCTAssertEqual(
            try String(contentsOf: folder.appendingPathComponent("lease_redacted.md"), encoding: .utf8),
            "an earlier note"
        )
    }

    // MARK: - Images (Vision OCR on a planted fixture)

    func testAnImageKeepsItsOwnTypeInTheOriginalFormatAndIsLeftOutOfMarkdown() async throws {
        let fixture = try ImageFixtureRenderer.writeJPEG(lines: ["Phone \(Self.phone)"])
        defer { try? FileManager.default.removeItem(at: fixture) }
        let model = try await scannedModel(for: fixture)

        let original = try await export(model, format: .original, into: "original")
        let image = try XCTUnwrap(original.redactedImageURL)
        XCTAssertEqual(image.pathExtension, "jpg")
        XCTAssertEqual(OutputFormatFixtures.imageType(image), "public.jpeg")
        XCTAssertEqual(original.redactedURL.pathExtension, "txt")

        let markdown = try await export(model, format: .markdown, into: "markdown")
        XCTAssertEqual(markdown.redactedURL.pathExtension, "md")
        XCTAssertNil(markdown.redactedImageURL, "Markdown carries the text only")
        XCTAssertEqual(markdown.sealCandidateCount, 0)
        XCTAssertEqual(files(in: "markdown").filter { !$0.hasSuffix(".ldamap") }.count, 1)
    }

    // MARK: - Remembered choices

    func testBothRememberedFormatsStartAsMarkdownAndKeepTheLastChoice() throws {
        let suiteName = TestNamespace.suiteName("output-format")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AISettings.saveRedactedFormat(defaults: defaults), .markdown)
        XCTAssertEqual(AISettings.batchOutputFormat(defaults: defaults), .markdown)

        AISettings.setSaveRedactedFormat(.original, defaults: defaults)
        XCTAssertEqual(AISettings.saveRedactedFormat(defaults: defaults), .original)
        XCTAssertEqual(AISettings.batchOutputFormat(defaults: defaults), .markdown, "the two choices are separate")

        AISettings.setBatchOutputFormat(.original, defaults: defaults)
        XCTAssertEqual(AISettings.batchOutputFormat(defaults: defaults), .original)

        defaults.set("rtf", forKey: AISettings.batchOutputFormatKey)
        XCTAssertEqual(AISettings.batchOutputFormat(defaults: defaults), .markdown, "an unknown value reads as Markdown")
    }

    func testTheBatchWindowRunsTheFormatSettingsChose() {
        var chosen = RedactedOutputFormat.markdown
        let model = BatchAnonymizeModel(modelPath: { "/model" }, style: .token, format: { chosen })
        XCTAssertEqual(model.batchOptions(modelPath: "/model", passphrase: nil).format, .markdown)
        chosen = .original
        XCTAssertEqual(
            model.batchOptions(modelPath: "/model", passphrase: nil).format,
            .original,
            "a change made while the window is open applies to the next run"
        )
        XCTAssertEqual(model.batchOptions(modelPath: "/model", passphrase: "pw").protectionLabel, "passphrase")

        // Each mapping is sealed under the account Restore derives from its
        // own name, which is not always <base>_redacted.
        let protection = model.batchOptions(modelPath: "/model", passphrase: nil)
            .protection(URL(fileURLWithPath: "/out/lease_redacted_2.ldamap"))
        guard case .keychain(let account) = protection else {
            return XCTFail("without a passphrase the mapping goes into the Keychain")
        }
        XCTAssertEqual(account, "lease_redacted_2")
    }

    // MARK: - Save Redacted on a mixed PDF

    /// The review's finding: the review reads a mixed PDF's text layer only,
    /// so its scanned page was reprinted, values and all, in the original
    /// format. That save is refused now; Markdown, which holds only what was
    /// reviewed, still saves.
    func testAMixedPDFIsNotReprintedWithAPageTheReviewNeverRead() async throws {
        let scannedEmail = "quill.mere@example.org"
        let source = try OutputFormatFixtures.writeHybridPDF(
            typedLines: ["Tenant email \(Self.email)"],
            scannedLines: ["Contact \(scannedEmail)"],
            to: workDir.appendingPathComponent("mixed.pdf")
        )
        let model = try await scannedModel(for: source)
        XCTAssertFalse(model.documentText.contains(scannedEmail), "premise: the review never read the scanned page")

        do {
            _ = try await export(model, format: .original, into: "original")
            XCTFail("the original format must refuse a page the review never read")
        } catch {
            XCTAssertEqual(error as? RedactedOutputError, .sourceNotReviewed)
            XCTAssertNotNil(RedactedOutputFormatPresentation.refusal(error, language: .simplifiedChinese))
        }
        XCTAssertEqual(files(in: "original"), [], "nothing is written")

        let markdown = try await export(model, format: .markdown, into: "markdown")
        let text = try String(contentsOf: markdown.redactedURL, encoding: .utf8)
        XCTAssertFalse(text.contains(Self.email))
        XCTAssertFalse(text.contains(scannedEmail))
    }

    // MARK: - The remembered format

    func testTheSheetRemembersAFormatOnlyWhenASaveWithItSucceeds() async throws {
        let suiteName = TestNamespace.suiteName("save-format-memory")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let flow = ExportFlowModel(defaults: defaults)
        XCTAssertEqual(flow.format, .markdown)

        // Chosen, then the sheet is cancelled.
        flow.format = .original
        flow.resetInput()
        XCTAssertEqual(flow.format, .markdown, "a cancelled choice is not remembered")

        // Chosen, and the save fails.
        flow.format = .original
        _ = await flow.save { throw DocumentIOError.unreadable("synthetic failure") }
        XCTAssertEqual(AISettings.saveRedactedFormat(defaults: defaults), .markdown, "a failed save is not remembered")

        // Chosen, and the save succeeds.
        _ = await flow.save {
            ExportResult(redactedURL: URL(fileURLWithPath: "/tmp/a_redacted.docx"), mappingURL: nil, tokenCount: 1)
        }
        XCTAssertEqual(AISettings.saveRedactedFormat(defaults: defaults), .original)
        flow.dismissSuccess()
        flow.resetInput()
        XCTAssertEqual(flow.format, .original, "the next sheet opens on it")
    }

    // MARK: - The words

    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/LDAUI/Resources", isDirectory: true)

    func testEverySentenceTheChoiceShowsIsInAllFourCatalogs() throws {
        var keys = Set<String>()
        for format in RedactedOutputFormat.allCases {
            keys.insert(RedactedOutputFormatPresentation.labelKey(format))
            keys.insert(RedactedOutputFormatPresentation.batchExplanationKey(format))
            for ext in ["docx", "pdf", "png", "jpg", "jpeg", "txt", "md", ""] {
                keys.insert(RedactedOutputFormatPresentation.saveExplanationKey(format, sourceExtension: ext))
            }
        }
        XCTAssertEqual(keys.count, 10, "two labels, two batch sentences, six Save Redacted sentences")
        for identifier in ["en", "fr", "zh-Hans", "zh-Hant"] {
            let url = Self.resources.appendingPathComponent("\(identifier).lproj/Localizable.strings")
            let catalog = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], identifier)
            for key in keys {
                XCTAssertNotNil(catalog[key], "\(identifier) lacks: \(key)")
            }
        }
    }

    func testTheSentenceUnderThePickerSpeaksAboutTheOpenDocument() {
        XCTAssertTrue(
            RedactedOutputFormatPresentation.saveExplanationKey(.markdown, sourceExtension: "DOCX")
                .contains("Headers, footers, notes and comments are left out")
        )
        XCTAssertTrue(
            RedactedOutputFormatPresentation.saveExplanationKey(.original, sourceExtension: "pdf").hasPrefix("A PDF")
        )
        XCTAssertTrue(
            RedactedOutputFormatPresentation.saveExplanationKey(.original, sourceExtension: "jpeg").hasPrefix("The image")
        )
        XCTAssertEqual(
            RedactedOutputFormatPresentation.saveExplanationKey(.original, sourceExtension: "md"),
            "The same kind of text file, line for line."
        )
    }

    func testARefusalOfTheOriginalFormatIsSaidInTheInterfaceLanguage() {
        let error = RedactedOutputError.valuesNotCovered(count: 2)
        let chinese = try? XCTUnwrap(RedactedOutputFormatPresentation.refusal(error, language: .simplifiedChinese))
        XCTAssertEqual(chinese?.contains("2"), true)
        XCTAssertEqual(chinese?.contains("Markdown"), true)
        XCTAssertFalse(chinese?.contains("could not be found") ?? true, "it is translated")
        XCTAssertNil(RedactedOutputFormatPresentation.refusal(DocumentIOError.ocrUnavailable))
    }
}
