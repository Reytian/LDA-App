//
//  PseudonymOverrideReplyProvenanceTests.swift
//  LDACoreTests
//
//  A user-forced pseudonym can also be ordinary language in an AI reply. The
//  mapping must remember how many forced replacements the handoff emitted. If
//  more come back, no occurrence can be attributed safely, so all stay
//  pseudonymized and the replacement is reported as ambiguous.
//
//  House rules: English only. Fixture values may be Chinese. No em-dash and
//  no en-dash-as-separator.
//

import XCTest
@testable import LDACore

final class PseudonymOverrideReplyProvenanceTests: XCTestCase {

    private static let createdAt = "2026-09-01T00:00:00Z"
    private let surface = "王小明"
    private let forcedReplacement = "借款人"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PseudonymOverrideReplyProvenanceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func spans(of value: String, in text: String) -> [Span] {
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        var result: [Span] = []
        while search.length > 0 {
            let range = ns.range(of: value, options: [], range: search)
            guard range.location != NSNotFound else { break }
            result.append(
                Span(
                    start: range.location,
                    end: range.location + range.length,
                    type: .person,
                    text: value,
                    source: .manual,
                    confidence: 1.0,
                    priority: 10
                )
            )
            let next = range.location + range.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return result
    }

    private func forcedMapping(document: String) throws -> TokenizeResult {
        try Tokenizer.tokenize(
            text: document,
            spans: spans(of: surface, in: document),
            sourceFile: "reply.txt",
            createdAtISO8601: Self.createdAt,
            style: .pseudonym,
            overrides: [surface: forcedReplacement]
        )
    }

    private func assertExtraForcedOccurrenceIsRefused(
        mapping: Mapping,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reply = "借款人签字。另请借款人确认。"
        let restored = Restorer.restore(text: reply, mapping: mapping)

        XCTAssertEqual(restored.text, reply, file: file, line: line)
        XCTAssertEqual(restored.restoredCount, 0, file: file, line: line)
        XCTAssertEqual(
            restored.ambiguousReplacements,
            [forcedReplacement],
            "every occurrence is uncertain once the reply exceeds the emitted count",
            file: file,
            line: line
        )
        XCTAssertFalse(restored.text.contains(surface), file: file, line: line)
    }

    func testNormalForcedReplyCountStillRestores() throws {
        let tokenized = try forcedMapping(document: "王小明签字。")

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )

        XCTAssertEqual(restored.text, "王小明签字。")
        XCTAssertEqual(restored.restoredCount, 1)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
    }

    func testExtraForcedReplyOccurrenceLeavesEveryOccurrencePseudonymized() throws {
        let tokenized = try forcedMapping(document: "王小明签字。")

        assertExtraForcedOccurrenceIsRefused(mapping: tokenized.mapping)
    }

    func testTwoEmittedForcedOccurrencesStillRestoreWhenTwoComeBack() throws {
        let original = "王小明签字，王小明确认。"
        let tokenized = try forcedMapping(document: original)

        let restored = Restorer.restore(
            text: tokenized.tokenizedText,
            mapping: tokenized.mapping
        )

        XCTAssertEqual(restored.text, original)
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
    }

    func testSeededOverrideProvenanceIsRecountedForEachNewHandoff() throws {
        let earlier = try forcedMapping(document: "王小明签字，王小明确认。")
        let currentDocument = "王小明签字。"
        let current = SessionTokenizer.tokenize(
            documents: [
                SessionDocument(
                    name: "current.txt",
                    text: currentDocument,
                    spans: spans(of: surface, in: currentDocument)
                )
            ],
            sourceLabel: "Matter A",
            createdAtISO8601: Self.createdAt,
            seedMapping: earlier.mapping,
            style: .pseudonym
        )

        XCTAssertEqual(current.documents.first?.tokenizedText, "借款人签字。")
        assertExtraForcedOccurrenceIsRefused(mapping: current.mapping)
    }

    func testCurrentOverridePromotesOrdinarySeedEntryToCountedProvenance() throws {
        let seeded = MappingEntry(
            token: forcedReplacement,
            value: surface,
            type: .person,
            surfaceText: surface,
            aliases: []
        )
        let seed = Mapping(
            entries: [forcedReplacement: seeded],
            createdAtISO8601: Self.createdAt,
            sourceFile: "earlier.txt",
            style: .pseudonym
        )
        let document = "王小明签字。"

        let current = try Tokenizer.tokenize(
            text: document,
            spans: spans(of: surface, in: document),
            sourceFile: "current.txt",
            createdAtISO8601: Self.createdAt,
            seedMapping: seed,
            style: .pseudonym,
            overrides: [surface: forcedReplacement]
        )

        XCTAssertEqual(current.tokenizedText, "借款人签字。")
        XCTAssertEqual(
            current.mapping.entries[forcedReplacement]?.userOverrideEmissionCount,
            1
        )
        assertExtraForcedOccurrenceIsRefused(mapping: current.mapping)
    }

    func testCurrentOverridePromotesOrdinarySeedAliasToCountedProvenance() throws {
        let seeded = MappingEntry(
            token: forcedReplacement,
            value: "张三",
            type: .person,
            surfaceText: "张三",
            aliases: [surface]
        )
        let seed = Mapping(
            entries: [forcedReplacement: seeded],
            createdAtISO8601: Self.createdAt,
            sourceFile: "earlier.txt",
            style: .pseudonym
        )
        let document = "王小明签字。"

        let current = try Tokenizer.tokenize(
            text: document,
            spans: spans(of: surface, in: document),
            sourceFile: "current.txt",
            createdAtISO8601: Self.createdAt,
            seedMapping: seed,
            style: .pseudonym,
            overrides: [surface: forcedReplacement]
        )

        XCTAssertEqual(current.tokenizedText, "借款人签字。")
        XCTAssertEqual(
            current.mapping.entries[forcedReplacement]?.userOverrideEmissionCount,
            1
        )
        assertExtraForcedOccurrenceIsRefused(mapping: current.mapping)
    }

    func testOrdinaryMintedPseudonymKeepsItsExistingRestoreBehavior() throws {
        let original = "王小明签字。"
        let minted = Tokenizer.tokenize(
            text: original,
            spans: spans(of: surface, in: original),
            sourceFile: "reply.txt",
            createdAtISO8601: Self.createdAt,
            style: .pseudonym
        )
        let replacement = try XCTUnwrap(minted.mapping.entries.values.first?.token)
        let reply = "\(replacement)签字。另请\(replacement)确认。"

        let restored = Restorer.restore(text: reply, mapping: minted.mapping)

        XCTAssertEqual(restored.text, "王小明签字。另请王小明确认。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
    }

    func testLegacyPseudonymEntryWithoutProvenanceRemainsOrdinary() throws {
        let legacy = Data(
            #"{"entries":{"张某":{"aliases":[],"surfaceText":"王小明","token":"张某","type":"PERSON","value":"王小明"}},"createdAtISO8601":"2026-08-30T00:00:00Z","sourceFile":"legacy.txt","style":"pseudonym"}"#.utf8
        )
        let mapping = try JSONDecoder().decode(Mapping.self, from: legacy)

        let restored = Restorer.restore(
            text: "张某签字。另请张某确认。",
            mapping: mapping
        )

        XCTAssertEqual(restored.text, "王小明签字。另请王小明确认。")
        XCTAssertEqual(restored.restoredCount, 2)
        XCTAssertTrue(restored.ambiguousReplacements.isEmpty)
    }

    func testForcedProvenanceSurvivesPlainMappingSerialization() throws {
        let tokenized = try forcedMapping(document: "王小明签字。")
        let bytes = try JSONEncoder().encode(tokenized.mapping)
        let decoded = try JSONDecoder().decode(Mapping.self, from: bytes)

        assertExtraForcedOccurrenceIsRefused(mapping: decoded)
    }

    func testForcedProvenanceSurvivesEncryptedMappingAndParkedStores() throws {
        let tokenized = try forcedMapping(document: "王小明签字。")

        let mappingURL = workDir.appendingPathComponent("reply.ldamap")
        try MappingStore.save(
            tokenized.mapping,
            to: mappingURL,
            protection: .passphrase("mapping-pw")
        )
        let loadedMapping = try MappingStore.load(
            from: mappingURL,
            protection: .passphrase("mapping-pw")
        )
        assertExtraForcedOccurrenceIsRefused(mapping: loadedMapping)

        let parkedURL = workDir.appendingPathComponent("reply.ldaparked")
        try ParkedSessionStore.save(
            ParkedSessionState(mapping: tokenized.mapping, clientLabel: "Matter A"),
            to: parkedURL,
            protection: .passphrase("parked-pw")
        )
        let parked = try ParkedSessionStore.load(
            from: parkedURL,
            protection: .passphrase("parked-pw")
        )
        assertExtraForcedOccurrenceIsRefused(mapping: parked.mapping)
    }

    func testForcedProvenanceSurvivesPortableWorkspaceRoundTrip() throws {
        let tokenized = try forcedMapping(document: "王小明签字。")
        let manifest = WorkspaceManifest(
            formatVersion: WorkspaceArchive.currentFormatVersion,
            createdAtISO8601: Self.createdAt,
            appVersion: "test",
            matterLabel: "Matter A",
            matterScopeID: nil,
            substitutionStyle: .pseudonym,
            documents: []
        )
        let workspaceURL = workDir.appendingPathComponent("matter.ldawork")
        try WorkspaceArchive.write(
            WorkspacePayload(
                manifest: manifest,
                documentSources: [:],
                mapping: tokenized.mapping
            ),
            to: workspaceURL,
            passphrase: "workspace-pw"
        )

        let opened = try WorkspaceArchive.read(
            from: workspaceURL,
            passphrase: "workspace-pw"
        )
        defer { _ = opened.expansion.cleanUp() }

        assertExtraForcedOccurrenceIsRefused(mapping: try XCTUnwrap(opened.mapping))
    }
}
