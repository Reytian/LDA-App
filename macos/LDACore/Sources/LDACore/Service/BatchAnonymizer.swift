//
//  BatchAnonymizer.swift
//  LDACore
//
//  Batch anonymization: every supported document under one folder, each
//  written as its own redacted copy with its own mapping, with no review and
//  no confirmation step. `lda batch` and the app's batch window both run it.
//
//  What a batch does that one anonymize does not:
//  - It loads the model once for all of its documents.
//  - It never stops for a person. A value the model found but could not
//    anchor everywhere is redacted at its run-in places (by default
//    UnlocatedValuePolicy.protect: Review's Protect, applied without
//    asking). A document that still cannot be cleaned is refused, listed in
//    the report and left without output, and the batch moves on.
//  - It mirrors the source folder's layout under the output folder. Two
//    documents in one folder that share a base name ("lease.docx" and
//    "lease.pdf") would both write "lease_redacted.ldamap", so each of them
//    goes into its own subfolder ("lease (docx)", "lease (pdf)").
//  - It resumes. The report records every finished document with its
//    source's size and modification date. A later run with the same settings
//    into the same output folder skips a document whose outputs are still
//    there and whose source is unchanged.
//
//  The report names documents by their path under the source folder and
//  counts what was replaced. It holds no document text and no detected
//  value, so it can travel with the redacted copies.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Options

/// How a batch runs. See BatchAnonymizer.
public struct BatchOptions {
    /// The model that finds people's names, company names and addresses: the
    /// LDA V4 folder or a GGUF. Nil detects with patterns only.
    public var modelPath: String?
    /// How replacements are written.
    public var style: SubstitutionStyle
    /// What a value the model found but could not anchor everywhere does.
    public var unlocatedPolicy: UnlocatedValuePolicy
    /// Process every document again, including those an earlier run finished.
    public var redoFinished: Bool
    /// The sealing named in the report: "keychain" or "passphrase". Never the
    /// passphrase itself.
    public var protectionLabel: String
    /// How the mapping of the document at the given URL is sealed. The CLI
    /// and the app name Keychain accounts differently, and each looks a key
    /// up under its own name when it restores, so the caller decides.
    public var protection: (URL) -> MappingProtection

    public init(
        modelPath: String?,
        style: SubstitutionStyle = .token,
        unlocatedPolicy: UnlocatedValuePolicy = .protect,
        redoFinished: Bool = false,
        protectionLabel: String,
        protection: @escaping (URL) -> MappingProtection
    ) {
        self.modelPath = modelPath
        self.style = style
        self.unlocatedPolicy = unlocatedPolicy
        self.redoFinished = redoFinished
        self.protectionLabel = protectionLabel
        self.protection = protection
    }
}

// MARK: - Report

/// One document's line in a batch report.
public struct BatchItem: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Written in this run.
        case done
        /// Finished by an earlier run and unchanged since, so left as it was.
        case skipped
        /// Refused or failed. Nothing was written for it.
        case failed
    }

    /// The document's path under the source folder.
    public var source: String
    public var status: Status
    /// The redacted copy, as a path under the output folder.
    public var redactedFile: String?
    /// The encrypted mapping, as a path under the output folder.
    public var mappingFile: String?
    /// PDF input only: the image-only review copy with boxes over the values.
    public var reviewPDF: String?
    /// Image input only: the redacted PNG.
    public var redactedImage: String?
    /// Every replacement made, body and DOCX side parts alike.
    public var replacedCount: Int
    /// Values redacted at their run-in places without asking (see
    /// UnlocatedValuePolicy.protect).
    public var autoProtectedValueCount: Int
    /// Values the review PDF still shows, because no box could be drawn.
    public var unboxedTokenCount: Int
    /// DOCX images copied without scanning (signatures, stamps).
    public var embeddedMediaCount: Int
    /// DOCX tracked changes. Accept them before redacting for an exact round
    /// trip.
    public var trackedChangeCount: Int
    /// Wall time for this document, in seconds. 0 for a skipped document.
    public var seconds: Double
    /// Why a failed document was not written. Never document text.
    public var reason: String?
    /// The source's size in bytes and modification time (seconds since 1970)
    /// when it was processed, so a later run can tell whether it changed.
    public var sourceSize: Int64
    public var sourceModified: Double
}

/// The record of one batch run, written to the output folder as
/// `fileName` (JSON) and `summaryFileName` (plain text).
public struct BatchReport: Codable, Equatable, Sendable {
    public static let fileName = "lda-batch-report.json"
    public static let summaryFileName = "lda-batch-report.txt"
    public static let currentFormat = 1

    public var format: Int
    public var startedAt: String
    public var finishedAt: String?
    /// The source folder's name. Not its full path, which would name the
    /// user's home folder in a file meant to travel.
    public var sourceFolderName: String
    /// "LDA V4", a GGUF file name, or "patterns only".
    public var detection: String
    public var style: String
    public var mappingProtection: String
    public var unlocatedPolicy: String
    /// True when the run was stopped before every document was processed.
    public var cancelled: Bool
    public var items: [BatchItem]

    public var doneCount: Int { items.filter { $0.status == .done }.count }
    public var skippedCount: Int { items.filter { $0.status == .skipped }.count }
    public var failedCount: Int { items.filter { $0.status == .failed }.count }
    public var autoProtectedValueCount: Int {
        items.reduce(0) { $0 + $1.autoProtectedValueCount }
    }
}

/// Where a batch stands, reported before and after each document.
public struct BatchProgress: Sendable {
    /// The document's 1-based position in the batch.
    public let index: Int
    public let total: Int
    /// The document's path under the source folder.
    public let source: String
    /// Nil when the document is about to start; its report line once it is
    /// finished.
    public let item: BatchItem?
}

// MARK: - Runner

public enum BatchAnonymizer {

    /// Why a batch could not start at all.
    public enum BatchError: Error, Equatable, CustomStringConvertible {
        case sourceFolderMissing(String)
        case outputFolderIsSourceFolder

        public var description: String {
            switch self {
            case .sourceFolderMissing(let path):
                return "The source folder does not exist or is not a folder: \(path)"
            case .outputFolderIsSourceFolder:
                return "The output folder must not be the source folder."
            }
        }
    }

    /// Runs the batch: every document from `documents(in:excluding:)`, one at
    /// a time, with the model loaded once.
    ///
    /// Throws only when the batch cannot start: a missing source folder, an
    /// output folder that is the source folder, a model that cannot run.
    /// Whatever goes wrong with one document goes into its line of the
    /// report, and the batch carries on with the next.
    ///
    /// - Parameters:
    ///   - isCancelled: checked before each document. Once it returns true
    ///     the batch stops, marks the report cancelled and writes it.
    ///   - onProgress: called before and after each document, on the calling
    ///     thread.
    ///   - now: the clock, injectable for tests.
    public static func run(
        sourceFolder: URL,
        outputFolder: URL,
        options: BatchOptions,
        isCancelled: () -> Bool = { false },
        onProgress: (BatchProgress) -> Void = { _ in },
        now: () -> Date = Date.init
    ) throws -> BatchReport {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceFolder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BatchError.sourceFolderMissing(sourceFolder.path)
        }
        guard canonicalPath(sourceFolder) != canonicalPath(outputFolder) else {
            throw BatchError.outputFolderIsSourceFolder
        }
        // Loaded before anything is written: a model that cannot run refuses
        // the whole batch once, never one document after another.
        let detector = try LDAService.makeDetector(
            modelPath: options.modelPath,
            unlocatedPolicy: options.unlocatedPolicy
        )
        let documents = try documents(in: sourceFolder, excluding: outputFolder)
        let folders = outputFolders(for: documents, sourceFolder: sourceFolder, outputFolder: outputFolder)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        var report = BatchReport(
            format: BatchReport.currentFormat,
            startedAt: timestamp(now()),
            finishedAt: nil,
            sourceFolderName: sourceFolder.lastPathComponent,
            detection: detectionLabel(options.modelPath),
            style: options.style.rawValue,
            mappingProtection: options.protectionLabel,
            unlocatedPolicy: options.unlocatedPolicy.rawValue,
            cancelled: false,
            items: []
        )
        let earlier = options.redoFinished ? [:] : finishedItems(in: outputFolder, matching: report)

        for (offset, document) in documents.enumerated() {
            if isCancelled() {
                report.cancelled = true
                break
            }
            let source = relativePath(of: document, under: sourceFolder)
            onProgress(BatchProgress(index: offset + 1, total: documents.count, source: source, item: nil))
            let item: BatchItem
            if let finished = earlier[source], isUnchanged(finished, document: document, outputFolder: outputFolder) {
                item = skipping(finished)
            } else {
                item = process(
                    document,
                    source: source,
                    into: folders[document] ?? outputFolder,
                    outputFolder: outputFolder,
                    detector: detector,
                    options: options,
                    now: now
                )
            }
            report.items.append(item)
            // Rewritten after every document, so a run that is killed can be
            // resumed from what it finished. A failure here is not fatal: the
            // final write below reports it.
            try? write(report, to: outputFolder)
            onProgress(BatchProgress(index: offset + 1, total: documents.count, source: source, item: item))
        }

        report.finishedAt = timestamp(now())
        try write(report, to: outputFolder)
        try Data(summaryText(report).utf8).write(
            to: outputFolder.appendingPathComponent(BatchReport.summaryFileName),
            options: .atomic
        )
        return report
    }

    // MARK: Discovery and layout

    /// The documents a batch over `sourceFolder` processes, in sorted path
    /// order: FolderImporter's discovery (hidden entries, packages and
    /// symlinks skipped; .txt, .docx, .pdf, .png, .jpg, .jpeg), less Word's
    /// owner files ("~$lease.docx", written while a document is open) and
    /// anything under `outputFolder` when it sits inside the source folder.
    public static func documents(in sourceFolder: URL, excluding outputFolder: URL) throws -> [URL] {
        let outputPrefix = canonicalPath(outputFolder) + "/"
        // Only an output folder inside the source folder holds files that are
        // not documents of the batch. One that contains the source folder
        // holds every document, and must exclude none of them.
        let outputIsInside = outputPrefix.hasPrefix(canonicalPath(sourceFolder) + "/")
        return try FolderImporter.discoverDocuments(in: sourceFolder).filter { url in
            !url.lastPathComponent.hasPrefix("~$")
                && !(outputIsInside && canonicalPath(url).hasPrefix(outputPrefix))
        }
    }

    /// The folder each document's outputs go to: the mirror of its own
    /// folder under `outputFolder`, or, when another document in the same
    /// folder shares its base name (case aside), a subfolder of that mirror
    /// named "<base name> (<extension>)".
    public static func outputFolders(
        for documents: [URL],
        sourceFolder: URL,
        outputFolder: URL
    ) -> [URL: URL] {
        func relativeFolder(_ document: URL) -> String {
            (relativePath(of: document, under: sourceFolder) as NSString).deletingLastPathComponent
        }
        func groupKey(_ document: URL) -> String {
            relativeFolder(document) + "/" + document.deletingPathExtension().lastPathComponent.lowercased()
        }
        var groupSizes: [String: Int] = [:]
        for document in documents {
            groupSizes[groupKey(document), default: 0] += 1
        }
        var folders: [URL: URL] = [:]
        for document in documents {
            let folder = relativeFolder(document)
            let mirror = folder.isEmpty
                ? outputFolder
                : outputFolder.appendingPathComponent(folder, isDirectory: true)
            if groupSizes[groupKey(document), default: 0] > 1 {
                let base = document.deletingPathExtension().lastPathComponent
                let name = "\(base) (\(document.pathExtension.lowercased()))"
                folders[document] = mirror.appendingPathComponent(name, isDirectory: true)
            } else {
                folders[document] = mirror
            }
        }
        return folders
    }

    // MARK: One document

    private static func process(
        _ document: URL,
        source: String,
        into folder: URL,
        outputFolder: URL,
        detector: LDAService.Detector,
        options: BatchOptions,
        now: () -> Date
    ) -> BatchItem {
        let started = now()
        let stamp = sourceStamp(document)
        let fileManager = FileManager.default
        let folderExisted = fileManager.fileExists(atPath: folder.path)
        let before = Set((try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [])
        do {
            let result = try LDAService.anonymize(
                using: detector,
                input: document,
                outputDir: folder,
                protection: options.protection(document),
                createdAtISO8601: timestamp(now()),
                style: options.style
            )
            return BatchItem(
                source: source,
                status: .done,
                redactedFile: relativePath(of: result.redactedFileURL, under: outputFolder),
                mappingFile: relativePath(of: result.mappingFileURL, under: outputFolder),
                reviewPDF: result.visualPdfURL.map { relativePath(of: $0, under: outputFolder) },
                redactedImage: result.redactedImageURL.map { relativePath(of: $0, under: outputFolder) },
                replacedCount: result.entityCount,
                autoProtectedValueCount: result.autoProtectedValueCount,
                unboxedTokenCount: result.unboxedTokenCount,
                embeddedMediaCount: result.embeddedMediaCount,
                trackedChangeCount: result.trackedChangeCount,
                seconds: now().timeIntervalSince(started),
                reason: nil,
                sourceSize: stamp.size,
                sourceModified: stamp.modified
            )
        } catch {
            removeLeftovers(in: folder, keeping: before, folderExisted: folderExisted, outputFolder: outputFolder)
            return BatchItem(
                source: source,
                status: .failed,
                redactedFile: nil,
                mappingFile: nil,
                reviewPDF: nil,
                redactedImage: nil,
                replacedCount: 0,
                autoProtectedValueCount: 0,
                unboxedTokenCount: 0,
                embeddedMediaCount: 0,
                trackedChangeCount: 0,
                seconds: now().timeIntervalSince(started),
                reason: describe(error, policy: options.unlocatedPolicy),
                sourceSize: stamp.size,
                sourceModified: stamp.modified
            )
        }
    }

    /// A one-line reason for a document that was not written. Never document
    /// text: the errors it names carry counts, file names and short format
    /// details only.
    public static func describe(_ error: Error, policy: UnlocatedValuePolicy = .protect) -> String {
        switch error {
        case LDAServiceError.incompleteExtraction(let count):
            return "The model gave no usable answer for \(count) segment(s), so part of the "
                + "document was never scanned."
        case LDAServiceError.unanchoredEntities(let count) where policy == .protect:
            return "\(count) detected value(s) are written only inside longer words or in a form "
                + "the document does not have, so they could not be removed automatically. "
                + "Open the document in LDA to protect them."
        case LDAServiceError.unanchoredEntities(let count):
            return "\(count) detected value(s) are present in a form that could not be matched "
                + "exactly, so they could not be removed."
        case DocumentIOError.corrupt(let detail):
            return "The document is corrupt: \(detail)"
        case DocumentIOError.unsupportedFormat(let detail):
            return "Unsupported format: \(detail)"
        case DocumentIOError.unreadable(let detail):
            return "Could not read the document: \(detail)"
        case DocumentIOError.ocrUnavailable:
            return "OCR is required but unavailable on this system."
        case DocumentIOError.keychainError(let status):
            return "Keychain operation failed with status \(status)."
        default:
            return String(describing: error)
        }
    }

    // MARK: Resume

    /// The finished lines of the report an earlier run left in `outputFolder`,
    /// by source path, when that run used the same settings as `current`.
    /// Mixing two styles or two kinds of sealing in one output folder would
    /// be a surprise, so different settings start over.
    private static func finishedItems(in outputFolder: URL, matching current: BatchReport) -> [String: BatchItem] {
        let url = outputFolder.appendingPathComponent(BatchReport.fileName)
        guard let data = FileManager.default.contents(atPath: url.path),
              let earlier = try? JSONDecoder().decode(BatchReport.self, from: data),
              earlier.format == BatchReport.currentFormat,
              earlier.detection == current.detection,
              earlier.style == current.style,
              earlier.mappingProtection == current.mappingProtection,
              earlier.unlocatedPolicy == current.unlocatedPolicy else {
            return [:]
        }
        var finished: [String: BatchItem] = [:]
        for item in earlier.items where item.status != .failed {
            finished[item.source] = item
        }
        return finished
    }

    /// True when `item` describes `document` as it is now and its outputs are
    /// still in place.
    private static func isUnchanged(_ item: BatchItem, document: URL, outputFolder: URL) -> Bool {
        guard let mapping = item.mappingFile, let redacted = item.redactedFile else { return false }
        let stamp = sourceStamp(document)
        let fileManager = FileManager.default
        return stamp.size == item.sourceSize
            && stamp.modified == item.sourceModified
            && fileManager.fileExists(atPath: outputFolder.appendingPathComponent(mapping).path)
            && fileManager.fileExists(atPath: outputFolder.appendingPathComponent(redacted).path)
    }

    private static func skipping(_ finished: BatchItem) -> BatchItem {
        var item = finished
        item.status = .skipped
        item.seconds = 0
        item.reason = nil
        return item
    }

    // MARK: Files

    /// Removes what a failed attempt left in `folder`: every entry that was
    /// not there before it started, then the folder itself and its empty
    /// parents up to `outputFolder` when the attempt created them.
    private static func removeLeftovers(
        in folder: URL,
        keeping before: Set<String>,
        folderExisted: Bool,
        outputFolder: URL
    ) {
        let fileManager = FileManager.default
        for name in (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? [] where !before.contains(name) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
        guard !folderExisted else { return }
        let root = canonicalPath(outputFolder) + "/"
        var current = folder
        while canonicalPath(current).hasPrefix(root),
              let entries = try? fileManager.contentsOfDirectory(atPath: current.path),
              entries.isEmpty {
            try? fileManager.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }

    private static func write(_ report: BatchReport, to outputFolder: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: outputFolder.appendingPathComponent(BatchReport.fileName),
            options: .atomic
        )
    }

    /// The plain-text summary: the counts, then every failed document with its
    /// reason, then every written document that needs a look.
    static func summaryText(_ report: BatchReport) -> String {
        var lines = ["LDA batch report", ""]
        lines.append("Started: \(report.startedAt)")
        lines.append("Finished: \(report.finishedAt ?? "not finished")")
        if report.cancelled {
            lines.append("The batch was stopped before every document was processed.")
        }
        lines.append("Source folder: \(report.sourceFolderName)")
        lines.append("Detection: \(report.detection)")
        lines.append("Output style: \(report.style)")
        lines.append(report.mappingProtection == "passphrase"
            ? "Mappings: protected with a passphrase"
            : "Mappings: keys stored in the Keychain on this Mac")
        lines.append(report.unlocatedPolicy == UnlocatedValuePolicy.protect.rawValue
            ? "Values run into other text: protected automatically"
            : "Values run into other text: the document is refused")
        lines.append("")
        lines.append("Documents: \(report.items.count)")
        lines.append("Written: \(report.doneCount)")
        lines.append("Finished in an earlier run: \(report.skippedCount)")
        lines.append("Failed: \(report.failedCount)")
        let protectedDocuments = report.items.filter { $0.autoProtectedValueCount > 0 }.count
        if protectedDocuments > 0 {
            lines.append(
                "Values protected automatically: \(report.autoProtectedValueCount) "
                    + "in \(protectedDocuments) document(s)"
            )
        }
        let failed = report.items.filter { $0.status == .failed }
        if !failed.isEmpty {
            lines.append("")
            lines.append("Failed, nothing was written for these:")
            for item in failed {
                lines.append("- \(item.source): \(item.reason ?? "unknown error")")
            }
        }
        var checks: [String] = []
        for item in report.items where item.status != .failed {
            if item.unboxedTokenCount > 0 {
                checks.append(
                    "- \(item.source): the review PDF still shows \(item.unboxedTokenCount) value(s). "
                        + "Share the redacted text, not the review PDF."
                )
            }
            if item.embeddedMediaCount > 0 {
                checks.append(
                    "- \(item.source): \(item.embeddedMediaCount) embedded image(s) were copied "
                        + "without scanning (signatures, stamps)."
                )
            }
            if item.trackedChangeCount > 0 {
                checks.append(
                    "- \(item.source): \(item.trackedChangeCount) tracked change(s). Accept them "
                        + "before redacting for an exact round trip."
                )
            }
        }
        if !checks.isEmpty {
            lines.append("")
            lines.append("Check these:")
            lines.append(contentsOf: checks)
        }
        lines.append("")
        lines.append("Nobody reviewed these documents. Check a sample of the redacted copies before sharing them.")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Small helpers

    private static func detectionLabel(_ modelPath: String?) -> String {
        guard let modelPath else { return "patterns only" }
        if LDAV4Extractor.isModelDirectory(modelPath) { return LDAV4Extractor.displayName }
        return (modelPath as NSString).lastPathComponent
    }

    /// `url`'s path under `folder`, or its file name when it is not under it.
    static func relativePath(of url: URL, under folder: URL) -> String {
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        guard url.path.hasPrefix(prefix) else { return url.lastPathComponent }
        return String(url.path.dropFirst(prefix.count))
    }

    /// A path with symlinks resolved, so /tmp and /private/tmp compare equal.
    private static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func sourceStamp(_ url: URL) -> (size: Int64, modified: Double) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (
            Int64(values?.fileSize ?? 0),
            values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
