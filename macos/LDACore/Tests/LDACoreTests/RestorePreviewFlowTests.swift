//
//  RestorePreviewFlowTests.swift
//  LDACoreTests
//
//  Restore now shows the document before it writes it, and the save panel
//  moved to the end. The claims that flow has to keep:
//
//    1. Cancelling at the save panel writes NOTHING.
//    2. Approving writes exactly ONE file, at the path that was chosen.
//    3. Amending an existing mapping entry changes what is written.
//    4. Amending an orphan token, a damaged placeholder, or an ambiguous
//       site is REFUSED, and refusing it leaves the mapping untouched.
//    5. The format control decides the written container: a Word choice
//       produces a real ZIP package, a text choice stays UTF-8 text.
//
//  Those are driven through RestoreApproval.run with its two side effects
//  handed in as closures. Without that seam, "cancel writes nothing" would
//  only be checkable by clicking, which is exactly how the original bug
//  survived: the write was unconditional and nobody could see it.
//
//  The last test is a source scan, because the claim it guards cannot be
//  observed by running anything here. A dropped file's sandbox grant used to
//  be released in a `defer` on the dropping function, which was correct only
//  while the write finished inside that function. It no longer does. A defer
//  there would now revoke the grant before the write, and ONLY under the App
//  Sandbox, which neither XCTest nor the unsandboxed dev binary exercises.
//  That failure ships green, so the shape of the code is what gets pinned.
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
@testable import LDAUI

final class RestorePreviewFlowTests: XCTestCase {

    private static let email = "jane.doe@example.com"
    private static let body = "Please reach the client at \(email) before Friday."
    private static let createdAt = "2026-09-04T00:00:00Z"
    private static let passphrase = "restore-preview-flow-passphrase"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "RestorePreviewFlowTests-\(UUID().uuidString)",
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

    // MARK: - Fixture

    private struct Fixture {
        let edited: URL
        let mapping: Mapping
        let preview: RestorePreview
    }

    /// One anonymized round trip whose redacted text sits in a .md file, plus
    /// the preview the shell would compute for it. `extraText` appends to the
    /// returned Markdown so a case can add an orphan or a damaged shape.
    private func fixture(appending extraText: String = "") throws -> Fixture {
        let input = workDir.appendingPathComponent("letter.txt")
        try Data(Self.body.utf8).write(to: input)
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)
        let saved = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt
        )
        let redacted = try String(contentsOf: saved.redactedFileURL, encoding: .utf8)
        let edited = workDir.appendingPathComponent("Redacted for AI.md")
        try Data((redacted + extraText).utf8).write(to: edited)
        let mapping = try MappingStore.load(
            from: saved.mappingFileURL,
            protection: .passphrase(Self.passphrase)
        )
        let preview = try LDAService.restorePreview(editedRedacted: edited, mapping: mapping)
        return Fixture(edited: edited, mapping: mapping, preview: preview)
    }

    /// The real writer, so "nothing was written" and "exactly one file was
    /// written" are claims about the file system rather than about a spy.
    private func realWrite(_ file: URL, _ mapping: Mapping, _ output: URL) throws -> RestoreReport {
        try LDAService.restore(editedRedacted: file, mapping: mapping, output: output)
    }

    /// Every file the flow could have produced, so an unexpected second write
    /// is visible.
    private func restoredFiles() throws -> [String] {
        try FileManager.default
            .contentsOfDirectory(atPath: workDir.path)
            .filter { $0.contains("_restored") }
            .sorted()
    }

    /// The mapping key of the entry holding the fixture's email value.
    private func emailKey(in mapping: Mapping) throws -> String {
        try XCTUnwrap(
            mapping.entries.first { $0.value.value == Self.email }?.key,
            "the fixture must carry an email entry"
        )
    }

    // MARK: - Claim 1: cancel writes nothing

    func testCancellingAtTheSavePanelWritesNothing() throws {
        let fixture = try fixture()
        var writeCalls = 0

        let outcome = RestoreApproval.run(
            file: fixture.edited,
            mapping: fixture.mapping,
            preview: fixture.preview,
            amendments: [:],
            format: .markdown,
            chooseOutput: { _, _ in nil },
            write: { file, mapping, output in
                writeCalls += 1
                return try self.realWrite(file, mapping, output)
            }
        )

        guard case .cancelled = outcome else {
            return XCTFail("backing out of the save panel must report cancelled, got \(outcome)")
        }
        XCTAssertEqual(writeCalls, 0, "a cancelled approval must not reach the writer at all")
        XCTAssertEqual(try restoredFiles(), [], "a cancelled approval must leave no file behind")
    }

    // MARK: - Claim 2: approve writes one file, where it was asked to

    func testApprovingWritesExactlyOneFileAtTheChosenPath() throws {
        let fixture = try fixture()
        let chosen = workDir.appendingPathComponent("somewhere_restored.md")
        var offeredNames: [String] = []

        let outcome = RestoreApproval.run(
            file: fixture.edited,
            mapping: fixture.mapping,
            preview: fixture.preview,
            amendments: [:],
            format: .markdown,
            chooseOutput: { name, _ in
                offeredNames.append(name)
                return chosen
            },
            write: realWrite
        )

        guard case .written(let report) = outcome else {
            return XCTFail("an approved restore must report a write, got \(outcome)")
        }
        XCTAssertEqual(report.outputURL, chosen)
        XCTAssertEqual(try restoredFiles(), ["somewhere_restored.md"])
        XCTAssertEqual(
            offeredNames,
            ["Redacted for AI_restored.md"],
            "the panel must be offered the suggested name once, and only once"
        )
        XCTAssertEqual(try String(contentsOf: chosen, encoding: .utf8), Self.body)
    }

    // MARK: - Claim 3: an amendment reaches the written file

    func testAmendingAnExistingEntryChangesWhatIsWritten() throws {
        let fixture = try fixture()
        let key = try emailKey(in: fixture.mapping)
        let corrected = "john.roe@example.com"
        let chosen = workDir.appendingPathComponent("amended_restored.md")

        let outcome = RestoreApproval.run(
            file: fixture.edited,
            mapping: fixture.mapping,
            preview: fixture.preview,
            amendments: [key: corrected],
            format: .markdown,
            chooseOutput: { _, _ in chosen },
            write: realWrite
        )

        guard case .written = outcome else {
            return XCTFail("an approved restore must report a write, got \(outcome)")
        }
        let written = try String(contentsOf: chosen, encoding: .utf8)
        XCTAssertTrue(written.contains(corrected), "the amended value must be written")
        XCTAssertFalse(
            written.contains(Self.email),
            "the value the reader corrected must not also be written"
        )
        XCTAssertEqual(
            fixture.mapping.entries[key]?.value,
            Self.email,
            "the caller's mapping must not have been mutated"
        )
    }

    func testAnAmendmentEqualToTheRecordedValueChangesNothing() throws {
        let fixture = try fixture()
        let key = try emailKey(in: fixture.mapping)

        let amended = RestorePreviewModel.amended(
            fixture.mapping,
            with: [key: Self.email],
            preview: fixture.preview
        )

        XCTAssertEqual(amended, fixture.mapping)
    }

    // MARK: - Claim 4: the three refusals

    func testAmendingAnOrphanTokenIsRefused() throws {
        let fixture = try fixture(appending: "\nAlso copy {PERSON_9}.")
        XCTAssertEqual(
            fixture.preview.orphanTokens,
            ["{PERSON_9}"],
            "the fixture must produce exactly the orphan this case is about"
        )

        XCTAssertEqual(
            RestorePreviewModel.refusal(
                forAmending: "{PERSON_9}",
                mapping: fixture.mapping,
                preview: fixture.preview
            ),
            .notInMapping
        )

        switch RestorePreviewModel.amending(
            fixture.mapping,
            key: "{PERSON_9}",
            to: "Someone",
            preview: fixture.preview
        ) {
        case .success:
            XCTFail("typing a value for an orphan would mint an entry, not correct one")
        case .failure(let refusal):
            XCTAssertEqual(refusal, .notInMapping)
        }

        // And the refusal survives the batch path, so a refused key cannot
        // ride along with accepted ones.
        let amended = RestorePreviewModel.amended(
            fixture.mapping,
            with: ["{PERSON_9}": "Someone"],
            preview: fixture.preview
        )
        XCTAssertEqual(amended, fixture.mapping)
        XCTAssertFalse(
            RestorePreviewModel
                .amendableEntries(mapping: fixture.mapping, preview: fixture.preview)
                .contains { $0.key == "{PERSON_9}" },
            "an orphan must not even be offered a field"
        )
    }

    func testAmendingADamagedPlaceholderIsRefused() throws {
        let fixture = try fixture(appending: "\nCopy to [EMAIL_1] as well.")
        let damaged = try XCTUnwrap(
            fixture.preview.suspectPlaceholders.first,
            "the fixture must produce a damaged placeholder"
        )

        XCTAssertEqual(
            RestorePreviewModel.refusal(
                forAmending: damaged,
                mapping: fixture.mapping,
                preview: fixture.preview
            ),
            .damagedPlaceholder
        )
        XCTAssertFalse(
            RestorePreviewModel
                .amendableEntries(mapping: fixture.mapping, preview: fixture.preview)
                .contains { $0.key == damaged }
        )
    }

    func testAmendingAnAmbiguousSiteIsRefused() throws {
        // Two names share a surname, so both mask to the same asterisk form
        // and no single entity owns the site. The missing fact there is WHICH
        // entity, which is not a value the reader could type.
        let shared = "\u{5F20}*"
        let mapping = Mapping(
            entries: [
                shared: MappingEntry(
                    token: shared,
                    value: "\u{5F20}\u{4E09}",
                    type: .person,
                    surfaceText: "\u{5F20}\u{4E09}",
                    aliases: []
                ),
                "\(shared)#2": MappingEntry(
                    token: shared,
                    value: "\u{5F20}\u{56DB}",
                    type: .person,
                    surfaceText: "\u{5F20}\u{56DB}",
                    aliases: []
                )
            ],
            createdAtISO8601: Self.createdAt,
            sourceFile: "collision.txt",
            style: .asterisk
        )
        let edited = workDir.appendingPathComponent("collision.md")
        try Data("\(shared)\u{5DF2}\u{7B7E}\u{5B57}\u{3002}".utf8).write(to: edited)
        let preview = try LDAService.restorePreview(editedRedacted: edited, mapping: mapping)
        XCTAssertEqual(preview.ambiguousReplacements, [shared])

        for key in [shared, "\(shared)#2"] {
            XCTAssertEqual(
                RestorePreviewModel.refusal(
                    forAmending: key,
                    mapping: mapping,
                    preview: preview
                ),
                .ambiguousSite,
                "\(key) must be refused"
            )
        }
        XCTAssertEqual(
            RestorePreviewModel.amendableEntries(mapping: mapping, preview: preview),
            [],
            "a site nobody owns must offer no field at all"
        )
    }

    func testAnEmptyValueAndAnAbsentReplacementAreRefused() throws {
        let fixture = try fixture()
        let key = try emailKey(in: fixture.mapping)

        // An empty value is a deletion at every site, not a correction.
        switch RestorePreviewModel.amending(
            fixture.mapping,
            key: key,
            to: "",
            preview: fixture.preview
        ) {
        case .success: XCTFail("an empty value would erase the text at every site")
        case .failure(let refusal): XCTAssertEqual(refusal, .emptyValue)
        }

        // An entry this document does not spell has nothing to correct.
        var withStranger = fixture.mapping
        withStranger.entries["{COMPANY_7}"] = MappingEntry(
            token: "{COMPANY_7}",
            value: "Acme Ltd",
            type: .company,
            surfaceText: "Acme Ltd",
            aliases: []
        )
        XCTAssertEqual(
            RestorePreviewModel.refusal(
                forAmending: "{COMPANY_7}",
                mapping: withStranger,
                preview: fixture.preview
            ),
            .notInThisDocument
        )
    }

    // MARK: - Claim 5: the format control decides the container

    func testTheChosenFormatDecidesTheWrittenContainer() throws {
        let fixture = try fixture()

        for format in RestoreOutputFormat.choices(forInputExtension: "md") {
            let chosen = workDir.appendingPathComponent("by-format-\(format.rawValue)."
                + format.fileExtension)
            let outcome = RestoreApproval.run(
                file: fixture.edited,
                mapping: fixture.mapping,
                preview: fixture.preview,
                amendments: [:],
                format: format,
                chooseOutput: { _, _ in chosen },
                write: realWrite
            )
            guard case .written = outcome else {
                return XCTFail("\(format.rawValue) must write, got \(outcome)")
            }

            let data = try Data(contentsOf: chosen)
            if format == .word {
                XCTAssertEqual(
                    Array(data.prefix(2)),
                    [0x50, 0x4B],
                    "a Word choice must produce a real ZIP package, not text bytes"
                )
                XCTAssertEqual(try DocxImporter().importDocument(chosen).text, Self.body)
            } else {
                XCTAssertNotEqual(
                    Array(data.prefix(2)),
                    [0x50, 0x4B],
                    "a text choice must stay text"
                )
                XCTAssertEqual(String(data: data, encoding: .utf8), Self.body)
            }
        }
    }

    func testTheSuggestedNameCarriesTheChosenFormatsExtension() throws {
        let edited = workDir.appendingPathComponent("Redacted for AI.md")
        XCTAssertEqual(
            RestoreOutputFormat.markdown.suggestedName(for: edited),
            "Redacted for AI_restored.md"
        )
        XCTAssertEqual(
            RestoreOutputFormat.plainText.suggestedName(for: edited),
            "Redacted for AI_restored.txt"
        )
        XCTAssertEqual(
            RestoreOutputFormat.word.suggestedName(for: edited),
            "Redacted for AI_restored.docx"
        )
    }

    /// A Word edit surface offers only Word: flattening a formatted document
    /// into text would throw the formatting away silently. A text surface
    /// offers its own kind first.
    func testFormatChoicesAndTheirHonestWarning() {
        XCTAssertEqual(RestoreOutputFormat.choices(forInputExtension: "docx"), [.word])
        XCTAssertEqual(RestoreOutputFormat.initialChoice(forInputExtension: "docx"), .word)
        XCTAssertEqual(RestoreOutputFormat.initialChoice(forInputExtension: "md"), .markdown)
        XCTAssertEqual(RestoreOutputFormat.initialChoice(forInputExtension: "txt"), .plainText)

        // The plain-formatting sentence belongs to a Word output regenerated
        // from TEXT. Saying it about a Word input, whose runs are rewritten in
        // place, would be false.
        XCTAssertTrue(
            RestoreOutputFormat.warnsAboutPlainWordFormatting(
                inputExtension: "md",
                format: .word
            )
        )
        XCTAssertFalse(
            RestoreOutputFormat.warnsAboutPlainWordFormatting(
                inputExtension: "docx",
                format: .word
            )
        )
        XCTAssertFalse(
            RestoreOutputFormat.warnsAboutPlainWordFormatting(
                inputExtension: "md",
                format: .markdown
            )
        )
    }

    // MARK: - The amendable list is stable and value-independent

    /// The sheet computes its rows and its warnings once and lets only the
    /// text follow the typing. That is safe because neither the amendable set
    /// nor any warning list is a function of the values, and this pins it: a
    /// change that made ambiguity or orphanhood depend on a value would break
    /// the sheet's assumption silently.
    func testAnAmendmentChangesTheTextAndNothingElse() throws {
        let fixture = try fixture(appending: "\nAlso copy {PERSON_9}.")
        let key = try emailKey(in: fixture.mapping)
        let amended = RestorePreviewModel.amended(
            fixture.mapping,
            with: [key: "john.roe@example.com"],
            preview: fixture.preview
        )

        let after = RestorePreviewModel.recomputed(fixture.preview, mapping: amended)

        XCTAssertNotEqual(after.restoredText, fixture.preview.restoredText)
        XCTAssertEqual(after.restoredCount, fixture.preview.restoredCount)
        XCTAssertEqual(after.orphanTokens, fixture.preview.orphanTokens)
        XCTAssertEqual(after.suspectPlaceholders, fixture.preview.suspectPlaceholders)
        XCTAssertEqual(after.ambiguousReplacements, fixture.preview.ambiguousReplacements)
        XCTAssertEqual(
            RestorePreviewModel.amendableEntries(mapping: amended, preview: fixture.preview),
            RestorePreviewModel
                .amendableEntries(mapping: fixture.mapping, preview: fixture.preview)
                .map {
                    $0.key == key
                        ? RestorePreviewModel.AmendableEntry(
                            key: $0.key,
                            replacement: $0.replacement,
                            value: "john.roe@example.com",
                            type: $0.type
                        )
                        : $0
                }
        )
    }

    /// Dictionary order is not an order. The rows must not shuffle between
    /// runs, or the reader loses their place mid-correction.
    func testTheAmendableListIsInAStableOrder() throws {
        let fixture = try fixture()
        let once = RestorePreviewModel.amendableEntries(
            mapping: fixture.mapping,
            preview: fixture.preview
        )
        for _ in 0..<8 {
            XCTAssertEqual(
                RestorePreviewModel.amendableEntries(
                    mapping: fixture.mapping,
                    preview: fixture.preview
                ),
                once
            )
        }
        XCTAssertEqual(once.map(\.replacement), once.map(\.replacement).sorted())
    }

    // MARK: - The shape of the flow, which no probe here can observe

    func testTheShellAsksWhereToSaveOnlyAfterTheReaderHasApproved() throws {
        let source = try Self.uiSource("DeanonymizeShell.swift")

        XCTAssertTrue(
            source.contains("LDAService.restorePreview("),
            "the shell must compute the restore before showing anything"
        )
        XCTAssertTrue(
            source.contains(".sheet(item: $pending"),
            "the computed restore must be presented for approval"
        )
        XCTAssertFalse(
            source.contains("guard let output = chooseOutput(for: file)"),
            "the old order chose the destination before the restore was seen"
        )
        XCTAssertEqual(
            source.components(separatedBy: "NSSavePanel(").count - 1,
            1,
            "there must be exactly one save panel, and it must be the approval step's"
        )
        XCTAssertTrue(
            source.contains("chooseOutput: chooseOutput"),
            "the save panel must be reached only as RestoreApproval's dependency"
        )
    }

    func testADroppedFilesSandboxGrantOutlivesThePreviewSheet() throws {
        let shell = try Self.uiSource("DeanonymizeShell.swift")

        // The textual check is the point. A `defer` in this file would once
        // again tie the grant's lifetime to a function return that no longer
        // contains the write, and the resulting failure appears only under the
        // App Sandbox. The three occurrences of the word defer in this file
        // are prose explaining exactly that, so the code form is what is
        // banned.
        XCTAssertFalse(
            shell.contains("defer {"),
            "the dropped file's grant must not be released on a function return"
        )
        XCTAssertFalse(
            shell.contains("startAccessingSecurityScopedResource"),
            "the grant is taken by ScopedFileAccess, which owns its lifetime"
        )
        XCTAssertFalse(
            shell.contains("stopAccessingSecurityScopedResource"),
            "the grant is released by ScopedFileAccess, in one place"
        )
        XCTAssertTrue(
            shell.contains("let access = ScopedFileAccess(file)"),
            "the drop path must take an explicitly held grant"
        )
        XCTAssertTrue(
            shell.contains("onDismiss: releaseDroppedAccess"),
            "the grant must be given back when the sheet closes, either way"
        )
        XCTAssertTrue(
            shell.contains("access.release()"),
            "a flow that never reaches a sheet must release the grant itself"
        )

        let holder = try Self.uiSource("ScopedFileAccess.swift")
        XCTAssertTrue(holder.contains("func release()"))
        XCTAssertTrue(
            holder.contains("guard isHeld else { return }"),
            "release must be idempotent, so either finishing path may call it"
        )
        XCTAssertTrue(
            holder.contains("deinit"),
            "a forgotten release must still balance the grant"
        )
    }

    /// release() is called on both finishing paths, so calling it twice must
    /// be harmless. Only the balance is observable here; the sandbox refusal
    /// this guards is not reachable from an unsandboxed test process.
    func testReleasingAHeldGrantTwiceIsHarmless() throws {
        let file = workDir.appendingPathComponent("grant.md")
        try Data("x".utf8).write(to: file)

        let access = ScopedFileAccess(file)
        access.release()
        access.release()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "releasing a grant must not disturb the file itself"
        )
    }

    // MARK: - File access

    private static func uiSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LDAUI")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
