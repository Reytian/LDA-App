//
//  CLIBatch.swift
//  LDACLI
//
//  `lda batch`: every document under a folder, each with its own redacted
//  copy and mapping, with no confirmation step (BatchAnonymizer).
//
//  The model defaults to the LDA V4 folder inside the LDA.app this tool
//  belongs to. `lda anonymize` without --model looks for patterns only, and a
//  batch run that way would leave every name in every document;
//  --rules-only asks for it on purpose.
//
//  A passphrase is never taken from the command line here: --ask-passphrase
//  reads it from the terminal without echo, twice, so it reaches neither the
//  process list nor the shell history.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import ArgumentParser
import Darwin
import Foundation
import LDACore

/// batch subcommand.
struct Batch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Anonymize every document in a folder, one redacted copy and mapping each, with no confirmation step.",
        discussion: """
            Processes every .txt, .docx, .pdf, .png, .jpg and .jpeg file under --input-dir, \
            subfolders included (hidden files and Word's "~$" owner files are skipped), into the \
            same layout under --output-dir, and writes lda-batch-report.json and \
            lda-batch-report.txt there.

            A value the model found but could not match exactly because a letter or digit runs \
            into it ("Jordan Lee2") is redacted at those places, as Review's Protect does. A \
            document that still cannot be cleaned is skipped, nothing is written for it, and the \
            report says why. Run the same command again to resume: documents finished with the \
            same settings and unchanged since are skipped.

            Exit status: 0 when every document was written, 2 when the batch finished but at \
            least one document was not, 1 when the batch could not run.
            """
    )

    @Option(name: .long, help: "Folder of source documents. Subfolders are included.")
    var inputDir: String

    @Option(name: .long, help: "Folder for the redacted copies, the mappings and the batch report. Created when missing.")
    var outputDir: String

    @Option(name: .long, help: "The LDA V4 model folder or a GGUF model. Default: the LDA V4 model inside this LDA.app.")
    var model: String?

    @Flag(name: .long, help: "Detect with patterns only, without a model. People's names, company names and addresses are then not looked for.")
    var rulesOnly = false

    @Option(name: .long, help: "Output style: token (default), pseudonym or asterisk. See lda anonymize --help.")
    var style: SubstitutionStyle = .token

    @Flag(name: .long, help: "Protect every mapping with one passphrase, typed at a prompt and never on the command line. Without it each mapping's key goes into the login keychain, one item per document, and the mappings restore only on this Mac.")
    var askPassphrase = false

    @Flag(name: .long, help: "Refuse a document when a detected value is written run into other text, instead of redacting it there.")
    var refuseUnlocated = false

    @Flag(name: .long, help: "Process every document again, including those an earlier run finished.")
    var redo = false

    func validate() throws {
        if rulesOnly, model != nil {
            throw ValidationError("--rules-only and --model cannot be used together.")
        }
    }

    func run() throws {
        let modelPath: String?
        if rulesOnly {
            modelPath = nil
        } else if let model {
            modelPath = model
        } else if let bundled = LDAV4Extractor.bundledModelPath() {
            modelPath = bundled
        } else {
            throw CLIRuntimeError(BatchCLIError.modelNotFound)
        }
        let passphrase = askPassphrase ? try Self.askForPassphrase() : nil
        let options = BatchOptions(
            modelPath: modelPath,
            style: style,
            unlocatedPolicy: refuseUnlocated ? .refuse : .protect,
            redoFinished: redo,
            protectionLabel: passphrase == nil ? "keychain" : "passphrase",
            protection: { document in
                // The same account rule as `lda anonymize`, so `lda restore`
                // finds every key.
                LDACLI.protectionFor(
                    passphrase: passphrase,
                    derivedAccount: LDACLI.mappingBaseName(forInput: document)
                )
            }
        )
        let output = URL(fileURLWithPath: outputDir, isDirectory: true)
        let report: BatchReport
        do {
            report = try BatchAnonymizer.run(
                sourceFolder: URL(fileURLWithPath: inputDir, isDirectory: true),
                outputFolder: output,
                options: options,
                onProgress: { progress in
                    if let item = progress.item {
                        fputs(Self.progressLine(progress, item), stderr)
                    }
                }
            )
        } catch {
            throw CLIRuntimeError(error)
        }
        print(try CLIJSON.encode(BatchSummaryJSON(report: report, outputFolder: output)))
        if report.failedCount > 0 {
            throw ExitCode(2)
        }
    }

    /// One stderr line per finished document.
    static func progressLine(_ progress: BatchProgress, _ item: BatchItem) -> String {
        let position = "[\(progress.index)/\(progress.total)] \(item.source): "
        switch item.status {
        case .done:
            var line = position + "written, \(item.replacedCount) replaced"
            if item.autoProtectedValueCount > 0 {
                line += ", \(item.autoProtectedValueCount) protected automatically"
            }
            return line + String(format: " (%.1f s)\n", item.seconds)
        case .skipped:
            return position + "finished in an earlier run, skipped\n"
        case .failed:
            return position + "NOT WRITTEN: \(item.reason ?? "unknown error")\n"
        }
    }

    /// Reads the mappings' passphrase from the terminal, without echo, twice.
    static func askForPassphrase() throws -> String {
        guard let first = readSecret("Passphrase for the mappings: ") else {
            throw CLIRuntimeError(BatchCLIError.noTerminal)
        }
        guard !first.isEmpty else {
            throw CLIRuntimeError(BatchCLIError.emptyPassphrase)
        }
        guard let second = readSecret("Type the passphrase again: "), second == first else {
            throw CLIRuntimeError(BatchCLIError.passphraseMismatch)
        }
        return first
    }

    /// One line from the terminal with echo off, or nil when there is no
    /// terminal to read from.
    private static func readSecret(_ prompt: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 1024)
        let size = buffer.count
        guard let line = readpassphrase(prompt, &buffer, size, RPP_REQUIRE_TTY) else {
            return nil
        }
        return String(cString: line)
    }
}

/// Why `lda batch` stopped before processing anything.
enum BatchCLIError: Error, CustomStringConvertible {
    case modelNotFound
    case noTerminal
    case emptyPassphrase
    case passphraseMismatch

    var description: String {
        switch self {
        case .modelNotFound:
            return "The LDA V4 model was not found next to this tool. Pass --model with the LDA V4 "
                + "folder (LDA.app/Contents/Resources/LDA-V4), or --rules-only to detect with "
                + "patterns only."
        case .noTerminal:
            return "--ask-passphrase needs a terminal to read the passphrase from."
        case .emptyPassphrase:
            return "No passphrase was entered. Nothing was written."
        case .passphraseMismatch:
            return "The two passphrases differ. Nothing was written."
        }
    }
}

/// The JSON object the batch subcommand prints when it finishes.
struct BatchSummaryJSON: Codable, Equatable {
    let documents: Int
    let written: Int
    let skipped: Int
    let failed: Int
    let autoProtectedValueCount: Int
    let cancelled: Bool
    let reportFile: String
    let summaryFile: String

    init(report: BatchReport, outputFolder: URL) {
        documents = report.items.count
        written = report.doneCount
        skipped = report.skippedCount
        failed = report.failedCount
        autoProtectedValueCount = report.autoProtectedValueCount
        cancelled = report.cancelled
        reportFile = outputFolder.appendingPathComponent(BatchReport.fileName).path
        summaryFile = outputFolder.appendingPathComponent(BatchReport.summaryFileName).path
    }
}
