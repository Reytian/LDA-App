//
//  ModelImporter.swift
//  LDAUI
//
//  The verified offline import: the user already has a model file, on a drive
//  or in a Downloads folder, and LDA installs it as a catalog tier without
//  making any network request.
//
//  THIS FILE MAKES NO REQUEST OF ANY KIND and must never grow one. It does not
//  know about ModelHostAllowlist, sourceURL, or offlineSourceURL, and a test
//  asserts that. It also must never consult offline mode: a firm that sets the
//  managed offline preference and installs a model-less build has no other way
//  to get a model, so a gate here would leave that configuration permanently
//  patterns-only with no in-app remedy. The import IS the remedy.
//
//  Three decisions carry the design:
//
//   1. The BYTES decide which tier the file becomes. Not the file name, which
//      is renameable, and never the user, who cannot know: a wrong answer
//      installs a model under a tier whose measured memory ceiling and timing
//      do not describe it, and those figures drive MemoryGate and the picker's
//      promises. Size prefilter first, because it refuses a wrong file in
//      microseconds and can name the likely cause, then one streaming pass
//      that hashes and writes at the same time.
//
//   2. The only trustworthy digest is the one inside the signed app. A
//      SHA256SUMS file carried alongside the model from the same source proves
//      nothing an attacker who replaced the model could not also replace, and
//      reading a sibling of a panel-chosen file is the NSIsRelatedItemType trap
//      this project has already hit. So nothing next to the chosen file is ever
//      opened.
//
//   3. The file is COPIED into the app container, never referenced in place and
//      never moved. In the container the app owns it outright: no
//      security-scoped bookmark, survives relaunch, removable from the same
//      sheet. Moving a user's file out from under them is data loss from their
//      point of view, and under the sandbox it would need write access to the
//      source's parent that Powerbox does not grant.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import CryptoKit
import Foundation
import LDACore
import UniformTypeIdentifiers

// MARK: - Progress and outcome

/// Where an import has got to. nil (the importer's initial phase) means idle.
public enum ModelImportPhase: Equatable, Sendable {
    /// Checking the size and that there is room, before anything is opened.
    case preparing
    /// Streaming. Fraction complete, plus bytes written and expected.
    case copying(fraction: Double, received: Int64, expected: Int64)
    /// The stream finished; matching the digest and moving the file into place.
    case verifying
    /// Installed as this catalog tier.
    case installed(tierID: String)
    case failed(ModelImportError)
    case cancelled
}

/// Why an import did not complete.
///
/// Deliberately NOT carrying a "use it anyway" affordance, and deliberately not
/// pointing at the unchecked custom-model path: a refusal that teaches the user
/// how to route around itself is not a refusal.
public enum ModelImportError: Equatable, Sendable {
    /// Not enough free space. Both figures so the user can judge the gap.
    case insufficientDisk(neededBytes: Int64, freeBytes: Int64)
    /// The byte count is not that of any model in the catalog. Almost always a
    /// join that was never done, so the message says so.
    case sizeUnmatched(actualBytes: Int64)
    /// The right size, the wrong bytes. Nothing is installed.
    case digestUnmatched
    /// The chosen file could not be read at all.
    case unreadable(String)
    /// Could not write into the app container.
    case storage(String)

    public var message: String {
        localizedMessage(language: .english)
    }

    public func localizedMessage(language: AppLanguage? = nil) -> String {
        let locale = (language ?? AppLanguage.selected()).locale
        switch self {
        case let .insufficientDisk(needed, free):
            let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return String(
                format: L10n.string(
                    "Not enough disk space. This model needs %@ and there is %@ free.",
                    language: language
                ),
                locale: locale,
                n as NSString,
                f as NSString
            )
        case let .sizeUnmatched(actual):
            let a = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
            return String(
                format: L10n.string(
                    "That file is %@, which is not the size of any model LDA publishes. If you downloaded it in two parts, join both parts first and add the joined file.",
                    language: language
                ),
                locale: locale,
                a as NSString
            )
        case .digestUnmatched:
            return L10n.string(
                "That file is not one of LDA's published models, so it was not installed. Its checksum does not match any model in this version's catalog. If you downloaded it in parts, check that both parts finished downloading and that they were joined in the right order.",
                language: language
            )
        case let .unreadable(detail):
            return String(
                format: L10n.string(
                    "Could not read that file (%@). It was not installed.",
                    language: language
                ),
                locale: locale,
                detail as NSString
            )
        case let .storage(detail):
            return String(
                format: L10n.string("Could not save the model (%@).", language: language),
                locale: locale,
                detail as NSString
            )
        }
    }
}

// MARK: - Importer

/// Copies a user-supplied model file into the app container, verifying it
/// against the catalog while it copies.
///
/// App owned, not sheet owned, for the same reason as `ModelInstaller`: a
/// multi-gigabyte copy must survive the user closing Manage Models.
@MainActor
public final class ModelImporter: ObservableObject {

    /// The current phase, or nil when idle.
    @Published public private(set) var phase: ModelImportPhase?

    private let catalog: ModelCatalog
    private let fileManager: FileManager
    private let freeSpaceProvider: @Sendable () -> Int64?
    private let chunkBytes: Int

    /// The running copy, so a second press is refused rather than racing.
    private var running: Task<Void, Never>?
    /// Bumped when an import settles, so a late progress hop cannot overwrite
    /// the final phase.
    private var generation = 0
    /// nonisolated because the worker thread reads it once per chunk. CancelFlag
    /// is lock guarded, so this widens nothing.
    nonisolated private let cancelFlag = CancelFlag()

    /// Prefix of the temporary file the copy writes into. Kept inside the
    /// models root on purpose: the destination tier is not known until the
    /// digest is computed, and a temp in NSTemporaryDirectory could be on
    /// another volume, which would turn the final move into a second full copy.
    private static let tempPrefix = ".import-"
    private static let tempSuffix = ".part"

    /// Chunk size for the streaming copy. 4 MB is large enough that the syscall
    /// overhead disappears and small enough that a cancel is felt immediately.
    nonisolated public static let defaultChunkBytes = 4 * 1024 * 1024

    public init(
        catalog: ModelCatalog = .load(),
        fileManager: FileManager = .default,
        freeSpaceBytes: (@Sendable () -> Int64?)? = nil,
        chunkBytes: Int = ModelImporter.defaultChunkBytes
    ) {
        self.catalog = catalog
        self.fileManager = fileManager
        self.chunkBytes = max(1, chunkBytes)
        if let freeSpaceBytes {
            self.freeSpaceProvider = freeSpaceBytes
        } else {
            let manager = FileManagerBox(fileManager)
            self.freeSpaceProvider = {
                ModelCatalog.freeSpaceBytes(fileManager: manager.manager)
            }
        }
        sweepAbandonedTempFiles()
    }

    /// Whether a copy is in flight.
    public var isImporting: Bool {
        switch phase {
        case .preparing, .copying, .verifying: return true
        default: return false
        }
    }

    /// Forget a settled outcome, so reopening the sheet does not show a stale
    /// success or failure from an earlier session.
    public func reset() {
        guard !isImporting else { return }
        phase = nil
    }

    // MARK: Panel

    /// The one open panel for the verified import.
    ///
    /// Single definition on purpose: two panels would drift in their message,
    /// and this one's message is what tells a user to join their parts first.
    public static func presentPanel() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let gguf = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [gguf]
        }
        panel.message = L10n.string(
            "Choose the joined model file (.gguf). If you downloaded it in two parts, join them first."
        )
        panel.prompt = L10n.string("Add Model")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: Import

    /// Verify and install `url`. Returns the running task so a caller can wait
    /// for it, or nil when a copy is already in flight.
    ///
    /// Sandbox note, and this is the one defect class only the packaged build
    /// reveals: the security scope is opened HERE, on the main actor, before any
    /// work is dispatched, and released when the worker finishes. A `defer` in
    /// this function would release it before the worker read a single byte,
    /// which is exactly the bug `AISettings.ScopeHolder` documents.
    @discardableResult
    public func importFile(at url: URL) -> Task<Void, Never>? {
        guard running == nil else { return nil }

        let scoped = url.startAccessingSecurityScopedResource()
        phase = .preparing

        guard let size = fileSize(of: url) else {
            settle(.failed(.unreadable(url.lastPathComponent)), url: url, scoped: scoped)
            return nil
        }
        // The prefilter. A file that is not the size of any published model is
        // refused before a single byte is hashed, and the message can say why.
        guard !catalog.tiersMatching(size: size).isEmpty else {
            settle(.failed(.sizeUnmatched(actualBytes: size)), url: url, scoped: scoped)
            return nil
        }
        // Same rule as the download path, from the same helper, so the two
        // never disagree about how much room an install needs.
        let needed = size + 1_000_000_000
        if let free = freeSpaceProvider(), free < needed {
            settle(
                .failed(.insufficientDisk(neededBytes: needed, freeBytes: free)),
                url: url,
                scoped: scoped
            )
            return nil
        }
        guard let root = ModelCatalog.modelsRoot(fileManager: fileManager) else {
            settle(.failed(.storage("no model folder")), url: url, scoped: scoped)
            return nil
        }
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            settle(
                .failed(.storage(error.localizedDescription)), url: url, scoped: scoped
            )
            return nil
        }

        let temp = root.appendingPathComponent(
            "\(Self.tempPrefix)\(UUID().uuidString)\(Self.tempSuffix)"
        )
        cancelFlag.reset()
        let currentGeneration = generation
        let catalog = self.catalog
        let manager = FileManagerBox(self.fileManager)
        let chunk = self.chunkBytes
        let flag = self.cancelFlag

        let task = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.performImport(
                    from: url,
                    temp: temp,
                    expectedBytes: size,
                    catalog: catalog,
                    fileManager: manager.manager,
                    chunkBytes: chunk,
                    cancel: flag,
                    onProgress: { written in
                        Task { @MainActor in
                            self?.report(
                                written: written, expected: size,
                                generation: currentGeneration
                            )
                        }
                    },
                    onVerifying: {
                        Task { @MainActor in
                            self?.report(verifyingAt: currentGeneration)
                        }
                    }
                )
            }.value
            await MainActor.run {
                guard let importer = self else {
                    // The importer went away mid-copy. Release the scope
                    // anyway: an unbalanced start is a sandbox resource leak
                    // for the life of the process.
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    return
                }
                importer.settle(outcome, url: url, scoped: scoped)
            }
        }
        running = task
        return task
    }

    /// Stop an in-flight copy. The temp file is removed by the worker.
    public func cancel() {
        guard isImporting else { return }
        cancelFlag.cancel()
    }

    // MARK: Phase updates

    private func report(written: Int64, expected: Int64, generation: Int) {
        guard generation == self.generation, isImporting else { return }
        let fraction = expected > 0
            ? min(1.0, Double(written) / Double(expected)) : 0
        phase = .copying(fraction: fraction, received: written, expected: expected)
    }

    private func report(verifyingAt generation: Int) {
        guard generation == self.generation, isImporting else { return }
        phase = .verifying
    }

    /// Record the outcome, release the security scope, and allow a new import.
    private func settle(_ outcome: ModelImportPhase, url: URL, scoped: Bool) {
        generation += 1
        running = nil
        phase = outcome
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    // MARK: Helpers

    private func fileSize(of url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else {
            return nil
        }
        return Int64(size)
    }

    /// Delete temp files a killed copy left behind.
    ///
    /// One sweep at construction: without it a process killed mid-copy leaves a
    /// multi-gigabyte `.part` in the container with nothing to notice it. Only
    /// this importer's own prefix is touched.
    ///
    /// This assumes ONE importer per process, which LDAApp guarantees: it owns
    /// a single `@StateObject` inside a `Window` scene and threads it by
    /// reference to Settings, RootShell and the sheets. A second instance would
    /// sweep a live sibling's in-flight `.part` out from under it. If a second
    /// one ever becomes necessary, give the temp name a per-instance component
    /// and sweep only that, rather than dropping the sweep.
    private func sweepAbandonedTempFiles() {
        guard let root = ModelCatalog.modelsRoot(fileManager: fileManager),
              let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
            return
        }
        for name in names
        where name.hasPrefix(Self.tempPrefix) && name.hasSuffix(Self.tempSuffix) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }

    // MARK: The worker

    /// Stream, hash, match, install. Runs off the main actor.
    ///
    /// One pass on purpose: the digest is computed DURING the copy, so hashing
    /// costs no extra IO. Reading 2.6 GB twice would double a wall time the
    /// user is already watching.
    nonisolated private static func performImport(
        from source: URL,
        temp: URL,
        expectedBytes: Int64,
        catalog: ModelCatalog,
        fileManager: FileManager,
        chunkBytes: Int,
        cancel: CancelFlag,
        onProgress: @escaping @Sendable (Int64) -> Void,
        onVerifying: @escaping @Sendable () -> Void
    ) -> ModelImportPhase {
        let stream = copy(
            from: source,
            to: temp,
            expectedBytes: expectedBytes,
            fileManager: fileManager,
            chunkBytes: chunkBytes,
            cancel: cancel,
            onProgress: onProgress
        )
        switch stream {
        case .cancelled:
            try? fileManager.removeItem(at: temp)
            return .cancelled
        case let .failure(error):
            try? fileManager.removeItem(at: temp)
            return .failed(error)
        case let .digest(hex):
            onVerifying()
            // The catalog inside the signed app is the only reference trusted
            // here. Nothing that travelled with the file is consulted.
            guard let tier = catalog.tier(matchingSha256: hex) else {
                try? fileManager.removeItem(at: temp)
                return .failed(.digestUnmatched)
            }
            guard let destination = ModelCatalog.installedURL(
                for: tier, fileManager: fileManager
            ) else {
                try? fileManager.removeItem(at: temp)
                return .failed(.storage("no install location for \(tier.id)"))
            }
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                // Same volume as the temp file, so this is a rename.
                try fileManager.moveItem(at: temp, to: destination)
            } catch {
                try? fileManager.removeItem(at: temp)
                return .failed(.storage(error.localizedDescription))
            }
            return .installed(tierID: tier.id)
        }
    }

    /// What one streaming pass produced.
    private enum StreamOutcome {
        case digest(String)
        case cancelled
        case failure(ModelImportError)
    }

    /// Read `source` and write `temp` in one pass, hashing as it goes.
    nonisolated private static func copy(
        from source: URL,
        to temp: URL,
        expectedBytes: Int64,
        fileManager: FileManager,
        chunkBytes: Int,
        cancel: CancelFlag,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) -> StreamOutcome {
        guard let reader = try? FileHandle(forReadingFrom: source) else {
            return .failure(.unreadable(source.lastPathComponent))
        }
        defer { try? reader.close() }
        guard fileManager.createFile(atPath: temp.path, contents: nil),
              let writer = try? FileHandle(forWritingTo: temp) else {
            return .failure(.storage(temp.lastPathComponent))
        }
        defer { try? writer.close() }

        var hasher = SHA256()
        var written: Int64 = 0
        // Report on whole-percent changes rather than once per chunk. A 2.6 GB
        // file is 654 chunks, and every report is a main-actor hop that
        // re-renders the shell; a progress bar cannot show more than 100 steps
        // anyway. The first and last updates always go through, so a caller
        // watching the phase stream still sees the copy begin and finish.
        var lastReportedPercent = -1
        while true {
            if cancel.isCancelled { return .cancelled }
            let chunk: Data?
            do {
                chunk = try reader.read(upToCount: chunkBytes)
            } catch {
                return .failure(.unreadable(source.lastPathComponent))
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            do {
                try writer.write(contentsOf: chunk)
            } catch {
                return .failure(.storage(error.localizedDescription))
            }
            written += Int64(chunk.count)
            let percent = expectedBytes > 0
                ? Int(Double(written) / Double(expectedBytes) * 100) : 100
            if percent != lastReportedPercent || written == expectedBytes {
                lastReportedPercent = percent
                onProgress(written)
            }
#if DEBUG
            afterChunkSeam.value?(written)
#endif
        }
        // Once more after the loop. The top-of-iteration check already catches
        // a cancel raised any time up to the last read, including during the
        // final chunk. What is left is the narrow window between that last
        // read of the flag and the file being moved into place: a click
        // arriving there would otherwise be absorbed and the import would
        // report .installed while the user had asked for the opposite.
        //
        // That window is microseconds wide and no test can hit it
        // deterministically, since the only seam fires after a chunk write. It
        // is cheap hardening, and the alternative is a Cancel press that
        // silently installs, so it stays.
        if cancel.isCancelled { return .cancelled }
        // A file that shrank under us is not the model it claimed to be, and
        // the digest would be a digest of something nobody published.
        guard written == expectedBytes else {
            return .failure(.sizeUnmatched(actualBytes: written))
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .digest(hex)
    }

    // MARK: - Test seam

#if DEBUG
    /// Invoked on the worker thread after each chunk is written, so a test can
    /// cancel at a known point rather than racing the copy. DEBUG only and lock
    /// guarded (see TestSeam): a release binary carries no such hook.
    nonisolated internal static let afterChunkSeam = TestSeam<@Sendable (Int64) -> Void>()

    /// Raise the cancel flag from the worker thread, so the cancellation test
    /// is deterministic rather than a race against a fast copy. The production
    /// `cancel()` hops through the main actor, which is right for a button and
    /// wrong for a test that must cancel before the next chunk is read.
    nonisolated internal func cancelFromWorkerForTesting() {
        cancelFlag.cancel()
    }
#endif
}

// MARK: - Cancellation

/// Carries a FileManager across the worker boundary.
///
/// FileManager is not Sendable, and it never will be. The instances that reach
/// here are `FileManager.default`, which is already shared by everything in the
/// process, or a test double that redirects one directory lookup and holds no
/// mutable state. The worker is the only thing using it while the copy runs.
struct FileManagerBox: @unchecked Sendable {
    let manager: FileManager
    init(_ manager: FileManager) { self.manager = manager }
}

/// A thread-safe cancel flag, checked once per chunk by the copy loop.
///
/// Its own small type rather than `Task.isCancelled` because the flag is set
/// from the main actor while the loop reads it on a worker thread, and because
/// cancelling the import must not cancel the enclosing task before its cleanup
/// has run.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    func reset() {
        lock.withLock { cancelled = false }
    }
}
