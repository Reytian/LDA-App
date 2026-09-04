//
//  ExportKeyHomeAndSidecarScopeTests.swift
//  LDACoreTests
//
//  The two defects that stopped the sidecar-defaults work from merging as
//  written, each pinned by the case that was missing.
//
//  1. A REDACTED DOCUMENT WITH ITS KEY NOWHERE. ReviewModel.export declares
//     keepMapping with a default of { _ in nil }, and the fail-closed guard
//     used to sit inside the catch, so it only fired when the closure THREW. A
//     nil return is not an error, and with no passphrase there is no sidecar
//     either, so the ordinary path wrote a redacted file whose mapping had no
//     home and reported success. Nothing threw, so nothing was cleaned up, and
//     the file looked like a finished deliverable that could never be
//     reversed. That is the worst outcome this product has.
//
//     The branch tested the throwing case and passed. No test called export
//     with passphrase: nil and the defaulted closure, which is the shape a
//     caller gets for free.
//
//  2. A SIDECAR CARRYING OTHER DOCUMENTS. The tokenizer is seeded with the
//     session mapping so one company keeps one token across a sitting, which
//     is correct. But that makes the tokenized mapping hold every other open
//     document's entries, and the sidecar is the file the export sheet tells
//     the user to keep and send. A sidecar for one matter was shipping another
//     matter's names.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ExportKeyHomeAndSidecarScopeTests: XCTestCase {

    private static let createdAt = "2026-09-04T12:00:00Z"

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-key-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func write(_ name: String, _ body: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        return url
    }

    private func outputDirectory(_ name: String = "out") -> URL {
        workDir.appendingPathComponent(name, isDirectory: true)
    }

    private func contents(of directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []).map(\.lastPathComponent).sorted()
    }

    // MARK: - 1. The key must land somewhere, or nothing is written

    func testAnExportWithNoPassphraseAndNoKeptMappingRefusesRatherThanStranding() async throws {
        let model = ReviewModel(modelPath: nil)
        await model.open(try write("contract.txt", "Contact john@acme.example about the matter."))
        await model.anonymize()
        let outputDir = outputDirectory()

        do {
            _ = try await model.export(
                to: outputDir,
                passphrase: nil,
                createdAtISO8601: Self.createdAt,
                keepMapping: { _ in nil }   // the DEFAULT value, stated explicitly
            )
            XCTFail(
                "an export with no passphrase and nowhere to keep the mapping "
                    + "must refuse. Succeeding here leaves a redacted document "
                    + "that nothing can ever restore."
            )
        } catch {
            // Expected. What matters is what is NOT on disk.
        }

        XCTAssertEqual(
            contents(of: outputDir), [],
            "the refusal must also remove what it had already written: a "
                + "redacted file left behind with no key reads as a finished "
                + "deliverable. Found: \(contents(of: outputDir))"
        )
    }

    /// The same call with a passphrase is fine: the key is beside the document.
    func testAnExportWithAPassphraseStandsEvenWithNoKeptMapping() async throws {
        let model = ReviewModel(modelPath: nil)
        await model.open(try write("contract.txt", "Contact john@acme.example about the matter."))
        await model.anonymize()
        let outputDir = outputDirectory()

        let result = try await model.export(
            to: outputDir,
            passphrase: "correct horse battery staple",
            createdAtISO8601: Self.createdAt,
            keepMapping: { _ in nil }
        )

        XCTAssertNotNil(
            result.mappingURL,
            "a passphrase export must write the sidecar that justifies letting "
                + "the export stand"
        )
        XCTAssertNil(result.workspaceURL)
    }

    // MARK: - 2. A sidecar carries this document and no other

    func testASidecarDoesNotCarryAnotherDocumentsValues() async throws {
        // Two documents, disjoint values, tokenized in one session so the
        // second export is seeded with the first document's mapping.
        let first = try write("alpha.txt", "Contact john@acme.example about Acme Holdings.")
        let second = try write("beta.txt", "Contact jane@beta.example about Beta Partners.")

        let model = ReviewModel(modelPath: nil)
        await model.open(first)
        await model.anonymize()
        let firstResult = try await model.export(
            to: outputDirectory("out-alpha"),
            passphrase: "pw-alpha",
            createdAtISO8601: Self.createdAt,
            keepMapping: { _ in nil }
        )
        let firstMappingURL = try XCTUnwrap(firstResult.mappingURL)
        let firstMapping = try MappingStore.load(
            from: firstMappingURL,
            protection: .passphrase("pw-alpha")
        )

        await model.open(second)
        await model.anonymize()
        let secondResult = try await model.export(
            to: outputDirectory("out-beta"),
            passphrase: "pw-beta",
            createdAtISO8601: Self.createdAt,
            seedMapping: firstMapping,
            keepMapping: { _ in nil }
        )
        let secondMappingURL = try XCTUnwrap(secondResult.mappingURL)
        let secondMapping = try MappingStore.load(
            from: secondMappingURL,
            protection: .passphrase("pw-beta")
        )

        let leaked = secondMapping.entries.values
            .map(\.value)
            .filter { $0.contains("john@acme.example") || $0.contains("Acme") }
        XCTAssertTrue(
            leaked.isEmpty,
            "beta.txt's sidecar carries alpha.txt's values: \(leaked). This is "
                + "the file the export sheet tells the user to keep and send, "
                + "so one matter's sidecar was shipping another matter's names."
        )
    }

    /// The narrowing must not cut too deep: every token the redacted document
    /// actually contains has to survive, or the sidecar restores to nothing.
    func testASidecarKeepsEveryTokenItsOwnDocumentSpells() async throws {
        let document = try write(
            "gamma.txt",
            "Contact jane@beta.example and also jane@beta.example again, plus 2026-01-02."
        )
        let model = ReviewModel(modelPath: nil)
        await model.open(document)
        await model.anonymize()

        let result = try await model.export(
            to: outputDirectory("out-gamma"),
            passphrase: "pw-gamma",
            createdAtISO8601: Self.createdAt,
            keepMapping: { _ in nil }
        )
        let mapping = try MappingStore.load(
            from: try XCTUnwrap(result.mappingURL),
            protection: .passphrase("pw-gamma")
        )
        let redacted = try String(contentsOf: result.redactedURL, encoding: .utf8)

        // Every replacement visible in the output must have an entry, which is
        // exactly the property restore depends on.
        let restored = try LDAService.restore(
            editedRedacted: result.redactedURL,
            mapping: mapping,
            output: workDir.appendingPathComponent("gamma-restored.txt")
        )
        XCTAssertTrue(
            restored.orphanTokens.isEmpty,
            "the narrowed sidecar dropped a token its own document spells, so "
                + "restore found orphans: \(restored.orphanTokens). Redacted "
                + "text was: \(redacted)"
        )
        let text = try String(contentsOf: restored.outputURL, encoding: .utf8)
        XCTAssertTrue(text.contains("jane@beta.example"))
    }

    // MARK: - The narrowing helper, directly

    func testNarrowingMatchesOnTheTokenNotTheDictionaryKey() {
        // An asterisk-style collision: two entities share one mask, so the
        // colliding entry lives under a disambiguated KEY while its token
        // keeps the shared replacement. Filtering on the key would drop it.
        let shared = "张*明"
        var mapping = Mapping(
            entries: [:],
            createdAtISO8601: Self.createdAt,
            sourceFile: "collision.txt",
            style: .asterisk
        )
        mapping.entries[shared] = MappingEntry(
            token: shared, value: "张小明", type: .person,
            surfaceText: "张小明", aliases: []
        )
        mapping.entries["\(shared)#2"] = MappingEntry(
            token: shared, value: "张大明", type: .person,
            surfaceText: "张大明", aliases: []
        )
        mapping.entries["{EMAIL_1}"] = MappingEntry(
            token: "{EMAIL_1}", value: "elsewhere@example.com", type: .email,
            surfaceText: "elsewhere@example.com", aliases: []
        )

        let narrowed = ReviewModel.mappingSpelledBy(
            mapping,
            tokenizedText: "The parties are \(shared) and \(shared).",
            nonBodyTokens: []
        )

        XCTAssertEqual(
            Set(narrowed.entries.keys), [shared, "\(shared)#2"],
            "both entries sharing the mask must survive, because restore cannot "
                + "tell them apart either and already reports that as an "
                + "ambiguous replacement rather than guessing"
        )
        XCTAssertNil(
            narrowed.entries["{EMAIL_1}"],
            "an entry whose token the document never spells belongs to another "
                + "document and must not travel in this sidecar"
        )
    }

    func testNarrowingKeepsNonBodyTokensTheDocumentDoesNotSpellInline() {
        var mapping = Mapping(
            entries: [:],
            createdAtISO8601: Self.createdAt,
            sourceFile: "header.docx",
            style: .token
        )
        mapping.entries["{PERSON_1}"] = MappingEntry(
            token: "{PERSON_1}", value: "In A Header", type: .person,
            surfaceText: "In A Header", aliases: []
        )
        let narrowed = ReviewModel.mappingSpelledBy(
            mapping,
            tokenizedText: "Body with no tokens at all.",
            nonBodyTokens: ["{PERSON_1}"]
        )
        XCTAssertEqual(
            Set(narrowed.entries.keys), ["{PERSON_1}"],
            "a docx header or footer token never appears in the body text, so "
                + "filtering on the body alone would drop it and its value "
                + "would restore as nothing"
        )
    }
}
