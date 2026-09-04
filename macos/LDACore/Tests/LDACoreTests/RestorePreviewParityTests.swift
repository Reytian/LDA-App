//
//  RestorePreviewParityTests.swift
//  LDACoreTests
//
//  LDAService.restorePreview is the seam that lets Restore show the document
//  before it writes it. Its whole value depends on one property: what the
//  preview says must be what the write reports. If the two ever diverge, the
//  sheet becomes a decoration and the reader approves a result that is not
//  the one they were shown.
//
//  So these tests assert PARITY, not shape: for the same input and the same
//  mapping, the preview's restoredCount, orphanTokens, suspectPlaceholders
//  and ambiguousReplacements equal the RestoreReport the write path returns.
//  They deliberately cover the awkward cases as well as the clean one: a
//  mangled placeholder (suspect), a token the mapping no longer holds
//  (orphan), a Word edit surface, and an asterisk-style mapping whose masks
//  collide (ambiguous).
//
//  WHAT IS NOT ASSERTED, on purpose: byte parity between preview.restoredText
//  and a written .docx. Under the token output style the Word write goes
//  through DocxRedactor.restore(tokenToValue:), which rewrites runs inside the
//  original package. The preview reports over DocxParts.restoreReportText,
//  which joins every visible text part for reporting. Those are two different
//  mechanisms over two different surfaces: the counts and the lists are
//  assertable and asserted below, the output bytes are not, and claiming
//  otherwise would be a promise the code does not make. For a TEXT edit
//  surface the restored text IS the bytes the writer receives, and that half
//  is asserted.
//
//  Deterministic-only (no GGUF model) and hermetic: every fixture lives under
//  the temporary directory with passphrase protection, so nothing touches the
//  macOS Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class RestorePreviewParityTests: XCTestCase {

    private static let email = "jane.doe@example.com"
    private static let phone = "13800138000"
    private static let body =
        "Please reach the client at \(email) or on \(phone) before Friday."
    private static let createdAt = "2026-09-04T00:00:00Z"
    private static let passphrase = "restore-preview-parity-passphrase"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RestorePreviewParityTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// One anonymized round trip. Returns the redacted text and its mapping.
    private func roundTrip(body: String = RestorePreviewParityTests.body) throws
        -> (redactedText: String, mapping: Mapping) {
        let input = workDir.appendingPathComponent("letter-\(UUID().uuidString).txt")
        try Data(body.utf8).write(to: input)
        let outputDir = workDir.appendingPathComponent(
            "out-\(UUID().uuidString)",
            isDirectory: true
        )
        let saved = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt
        )
        let redacted = try String(contentsOf: saved.redactedFileURL, encoding: .utf8)
        let mapping = try MappingStore.load(
            from: saved.mappingFileURL,
            protection: .passphrase(Self.passphrase)
        )
        return (redacted, mapping)
    }

    private func write(_ text: String, as name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func out(_ name: String) -> URL {
        workDir.appendingPathComponent(name)
    }

    // MARK: - The parity assertion itself

    /// The single check every case below funnels through: preview first, then
    /// the write, then equality of every reported field.
    private func assertPreviewMatchesTheWrite(
        edited: URL,
        mapping: Mapping,
        output: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (preview: RestorePreview, report: RestoreReport) {
        let preview = try LDAService.restorePreview(editedRedacted: edited, mapping: mapping)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.path),
            "restorePreview must not write anything",
            file: file,
            line: line
        )

        let report = try LDAService.restore(
            editedRedacted: edited,
            mapping: mapping,
            output: output
        )

        XCTAssertEqual(
            preview.restoredCount,
            report.restoredCount,
            "the preview's restored count must be the count the write reports",
            file: file,
            line: line
        )
        XCTAssertEqual(
            preview.orphanTokens,
            report.orphanTokens,
            "the preview's orphan list must be the list the write reports",
            file: file,
            line: line
        )
        XCTAssertEqual(
            preview.suspectPlaceholders,
            report.suspectPlaceholders,
            "the preview's damaged-placeholder list must be the list the write reports",
            file: file,
            line: line
        )
        XCTAssertEqual(
            preview.ambiguousReplacements,
            report.ambiguousReplacements,
            "the preview's ambiguous list must be the list the write reports",
            file: file,
            line: line
        )
        return (preview, report)
    }

    // MARK: - Text edit surface

    func testPreviewMatchesTheWriteForACleanMarkdownReturn() throws {
        let fixture = try roundTrip()
        let edited = try write(fixture.redactedText, as: "clean.md")

        let both = try assertPreviewMatchesTheWrite(
            edited: edited,
            mapping: fixture.mapping,
            output: out("clean_restored.md")
        )

        XCTAssertGreaterThan(both.report.restoredCount, 0, "the fixture must restore something")
        XCTAssertTrue(both.preview.orphanTokens.isEmpty)
        XCTAssertTrue(both.preview.suspectPlaceholders.isEmpty)
    }

    /// For a text edit surface the preview's restored text IS the string the
    /// writer receives, so this half of the parity is byte-exact and worth
    /// pinning: a reader who approved this text gets this file.
    func testPreviewTextIsExactlyWhatATextWriteProduces() throws {
        let fixture = try roundTrip()
        let edited = try write(fixture.redactedText, as: "exact.md")
        let output = out("exact_restored.md")

        let preview = try LDAService.restorePreview(
            editedRedacted: edited,
            mapping: fixture.mapping
        )
        _ = try LDAService.restore(
            editedRedacted: edited,
            mapping: fixture.mapping,
            output: output
        )

        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            preview.restoredText
        )
        XCTAssertEqual(preview.restoredText, Self.body)
    }

    /// A placeholder the external AI mangled: reported as a suspect by the
    /// write path, so the preview has to report the same one, with the same
    /// spelling, before anything is on disk.
    func testPreviewMatchesTheWriteForADamagedPlaceholder() throws {
        let fixture = try roundTrip()
        let damaged = fixture.redactedText.replacingOccurrences(of: "{EMAIL_1}", with: "[EMAIL_1]")
        XCTAssertNotEqual(damaged, fixture.redactedText, "the fixture must contain {EMAIL_1}")
        let edited = try write(damaged, as: "damaged.md")

        let both = try assertPreviewMatchesTheWrite(
            edited: edited,
            mapping: fixture.mapping,
            output: out("damaged_restored.md")
        )

        XCTAssertFalse(
            both.preview.suspectPlaceholders.isEmpty,
            "the fixture must produce at least one damaged placeholder"
        )
    }

    /// A token the mapping does not hold: an orphan. The preview must name it
    /// while the reader can still fix the mapping, not afterwards.
    func testPreviewMatchesTheWriteForAnOrphanToken() throws {
        let fixture = try roundTrip()
        let withOrphan = fixture.redactedText + "\nAlso copy {PERSON_9}."
        let edited = try write(withOrphan, as: "orphan.md")

        let both = try assertPreviewMatchesTheWrite(
            edited: edited,
            mapping: fixture.mapping,
            output: out("orphan_restored.md")
        )

        XCTAssertEqual(both.preview.orphanTokens, ["{PERSON_9}"])
    }

    /// The promoted output: a Markdown return asked to land in .docx. The
    /// counts stay assertable through the SimpleDocxWriter conversion.
    func testPreviewMatchesTheWriteWhenAMarkdownReturnLandsInWord() throws {
        let fixture = try roundTrip()
        let edited = try write(fixture.redactedText, as: "promoted.md")

        _ = try assertPreviewMatchesTheWrite(
            edited: edited,
            mapping: fixture.mapping,
            output: out("promoted_restored.docx")
        )
    }

    // MARK: - Word edit surface

    /// The .docx half of the parity: same counts and same lists, over
    /// DocxParts.restoreReportText, while the bytes go out through a different
    /// writer. See the file header for why only the counts are asserted.
    func testPreviewMatchesTheWriteForAWordEditSurface() throws {
        let fixture = try roundTrip()
        let edited = out("word-return.docx")
        try SimpleDocxWriter.write(fixture.redactedText, to: edited)

        let both = try assertPreviewMatchesTheWrite(
            edited: edited,
            mapping: fixture.mapping,
            output: out("word-return_restored.docx")
        )

        XCTAssertGreaterThan(both.report.restoredCount, 0)
        XCTAssertTrue(
            both.preview.restoredText.contains(Self.email),
            "the Word preview must show the real value it is about to write"
        )
    }

    // MARK: - Asterisk style, where masks can collide

    /// Two names sharing a surname mask to the same asterisk form, so no
    /// single entity owns the site and the restorer refuses it. The refusal
    /// has to be visible in the preview: it is exactly the kind of thing a
    /// reader must settle by hand, and it used to surface only after the file
    /// was written.
    func testPreviewMatchesTheWriteForAnAmbiguousAsteriskMask() throws {
        let mapping = Mapping(
            entries: [
                "\u{5F20}*": MappingEntry(
                    token: "\u{5F20}*",
                    value: "\u{5F20}\u{4E09}",
                    type: .person,
                    surfaceText: "\u{5F20}\u{4E09}",
                    aliases: []
                ),
                "\u{5F20}*#2": MappingEntry(
                    token: "\u{5F20}*",
                    value: "\u{5F20}\u{56DB}",
                    type: .person,
                    surfaceText: "\u{5F20}\u{56DB}",
                    aliases: []
                ),
                "\u{674E}*": MappingEntry(
                    token: "\u{674E}*",
                    value: "\u{674E}\u{4E94}",
                    type: .person,
                    surfaceText: "\u{674E}\u{4E94}",
                    aliases: []
                )
            ],
            createdAtISO8601: Self.createdAt,
            sourceFile: "collision.txt",
            style: .asterisk
        )
        let edited = try write(
            "\u{5F20}*\u{548C}\u{674E}*\u{5DF2}\u{7B7E}\u{5B57}\u{3002}",
            as: "collision.md"
        )

        let both = try assertPreviewMatchesTheWrite(
            edited: edited,
            mapping: mapping,
            output: out("collision_restored.md")
        )

        XCTAssertEqual(both.preview.ambiguousReplacements, ["\u{5F20}*"])
        XCTAssertEqual(
            both.preview.restoredCount,
            1,
            "only the unshared mask may be substituted"
        )
    }

    // MARK: - The guards a preview still has to run

    /// A redacted image cannot be restored. That refusal is about the INPUT
    /// alone, so the preview must refuse it too rather than letting the flow
    /// reach a sheet that has nothing to show.
    func testPreviewRefusesARedactedImageJustAsAWriteDoes() throws {
        let image = out("redacted.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        let mapping = Mapping(
            entries: [:],
            createdAtISO8601: Self.createdAt,
            sourceFile: "redacted.png"
        )

        XCTAssertThrowsError(
            try LDAService.restorePreview(editedRedacted: image, mapping: mapping)
        ) { error in
            guard case DocumentIOError.unsupportedFormat = error else {
                return XCTFail("expected an unsupportedFormat refusal, got \(error)")
            }
        }
    }

    /// The output-equals-input guard is a property of a WRITE and cannot be
    /// checked without a destination, so the preview does not attempt it. The
    /// write still does: pinning both halves keeps a future refactor from
    /// moving the check into the preview and quietly losing it.
    func testTheOutputEqualsInputGuardStaysOnTheWritePath() throws {
        let fixture = try roundTrip()
        let edited = try write(fixture.redactedText, as: "in-place.md")

        XCTAssertNoThrow(
            try LDAService.restorePreview(editedRedacted: edited, mapping: fixture.mapping),
            "a preview needs no destination, so it cannot collide with one"
        )
        XCTAssertThrowsError(
            try LDAService.restore(
                editedRedacted: edited,
                mapping: fixture.mapping,
                output: edited
            )
        ) { error in
            XCTAssertEqual(error as? LDAServiceError, .outputEqualsInput)
        }
    }
}
