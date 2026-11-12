//
//  OriginalFormatSeedTokenTests.swift
//  LDACoreTests
//
//  The independent review's F11 case through the original format: B saved on
//  day one; on day two A is saved first, then B again. The day-two B file
//  must carry the placeholders its own text and its session restore agree
//  on: the Word body, and a boxed PDF's labels and the text beside it.
//
//  Session scaffolding follows the review's ReviewerF11WordTests. Patterns
//  only, passphrase-sealed stores, Vision OCR to read the PDF's labels.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class OriginalFormatSeedTokenTests: XCTestCase {

    private static let createdAt = "2026-11-11T00:00:00Z"
    private static let lineA = "Engagement Letter. Mail alice@alpha.example about the matter."
    private static let lineB = "Engagement Letter. Mail bob@beta.example about the matter."

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalFormatSeedTokenTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func makeSession() -> SessionModel {
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: self.workDir.appendingPathComponent("clients")) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        session.recordStore = { try SessionRecordStore(rootDirectory: self.workDir.appendingPathComponent("records")) }
        session.recordProtection = { .passphrase("pw") }
        session.matterStore = { try MatterMetadataStore(rootDirectory: self.workDir.appendingPathComponent("matters")) }
        session.matterProtection = { .passphrase("pw") }
        let parked = workDir.appendingPathComponent("parked/parked.ldamap")
        try? FileManager.default.createDirectory(at: parked.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.parkedMappingURL = { parked }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.exportSidecarProtection = { _ in .passphrase("ai-sidecar-pw") }
        let workspaces = workDir.appendingPathComponent("workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        session.defaultWorkspaceDirectory = { workspaces }
        session.defaultWorkspaceProtection = { _ in .passphrase("workspace-pw") }
        return session
    }

    private func export(_ document: URL, from session: SessionModel, into folder: String) async throws -> ExportResult {
        let entry = try XCTUnwrap(session.entries.first { $0.url.standardizedFileURL == document.standardizedFileURL })
        session.selectedID = entry.id
        return try await session.exportRedacted(
            to: workDir.appendingPathComponent(folder, isDirectory: true),
            passphrase: nil,
            format: .original,
            createdAtISO8601: Self.createdAt
        )
    }

    /// The email placeholders in `text`, in order, as EMAIL_n. OCR of a box
    /// label can read the underscore as a space or drop it ("EMAIL 2",
    /// "EMAIL_ 2") and a brace as a bracket, so only the type and the number
    /// are compared.
    private func emailTokens(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "EMAIL[_ ]*([0-9]+)")
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { "EMAIL_" + ns.substring(with: $0.range(at: 1)) }
    }

    /// Day one saves B; day two saves A, then B. Returns day two's session
    /// and B's day-two result.
    private func dayTwo(_ a: URL, _ b: URL) async throws -> (SessionModel, ExportResult) {
        let day1 = makeSession()
        await day1.addDocuments([b])
        await day1.anonymizeAll()
        _ = try await export(b, from: day1, into: "day1")

        let day2 = makeSession()
        await day2.addDocuments([a, b])
        await day2.anonymizeAll()
        _ = try await export(a, from: day2, into: "day2")
        return (day2, try await export(b, from: day2, into: "day2"))
    }

    func testTheOriginalWordFileUsesThePlaceholdersItsSessionRestores() async throws {
        let a = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run(Self.lineA)),
            to: workDir.appendingPathComponent("alpha.docx")
        )
        let b = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run(Self.lineB)),
            to: workDir.appendingPathComponent("beta.docx")
        )
        let (day2, result) = try await dayTwo(a, b)

        let body = try DocxImporter().importDocument(result.redactedURL).text
        XCTAssertFalse(body.contains("bob@beta.example"), "the address is replaced; body: \(body)")
        XCTAssertEqual(emailTokens(in: body).count, 1, "body: \(body)")
        let restored = Restorer.restore(text: body, mapping: try XCTUnwrap(day2.sessionMapping)).text
        XCTAssertEqual(restored, Self.lineB, "the Word body restores to B's own address; body: \(body)")
    }

    func testABoxedPDFItsLabelsAndTheTextBesideItUseOnePlaceholder() async throws {
        let a = try OutputFormatFixtures.writePDF(
            [.init(size: OutputFormatFixtures.letter, lines: [Self.lineA])],
            metadataValue: "alpha",
            to: workDir.appendingPathComponent("alpha.pdf")
        )
        let b = try OutputFormatFixtures.writePDF(
            [.init(size: OutputFormatFixtures.letter, lines: [Self.lineB])],
            metadataValue: "beta",
            to: workDir.appendingPathComponent("beta.pdf")
        )
        let (day2, result) = try await dayTwo(a, b)

        let text = try String(contentsOf: result.redactedURL, encoding: .utf8)
        let boxed = try XCTUnwrap(result.redactedImageURL)
        let labels = try PdfOCRImporter().importDocument(boxed).text
        print("SEED-TOKEN text: \(text)")
        print("SEED-TOKEN labels read back: \(labels)")
        XCTAssertFalse(text.contains("bob@beta.example"), "the address is replaced in the text")
        XCTAssertFalse(labels.contains("beta.example"), "the address is boxed on the page")
        XCTAssertEqual(emailTokens(in: text).count, 1, "text: \(text)")
        XCTAssertEqual(emailTokens(in: labels), emailTokens(in: text), "the box label is the text's placeholder")
        let restored = Restorer.restore(text: text, mapping: try XCTUnwrap(day2.sessionMapping)).text
        XCTAssertEqual(restored, Self.lineB, "the text beside the PDF restores to B's own address")
    }
}
