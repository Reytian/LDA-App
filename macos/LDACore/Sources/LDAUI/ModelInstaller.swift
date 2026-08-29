//
//  ModelInstaller.swift
//  LDAUI
//
//  Downloading, verifying, and removing detection models.
//
//  THIS FILE IS THE ONLY PLACE IN THE APP THAT TOUCHES THE NETWORK. The app
//  carries com.apple.security.network.client for exactly one purpose:
//  downloading a model the user explicitly asked for. Document content never
//  leaves the machine. If you are auditing, `grep -rn URLSession Sources/`
//  should return hits in this file and nowhere else. Any other use is a defect.
//
//  Integrity: a model file decides what gets redacted, so a corrupted or
//  substituted download is a correctness problem, not just an annoyance. Two
//  layers run on every download, cheapest first:
//    1. Byte count against the manifest, which catches a truncated transfer.
//    2. SHA-256 computed DURING the copy, so hashing costs no extra IO, and
//       compared against the manifest when the manifest carries a digest.
//  A file that fails either check is deleted rather than installed.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import CryptoKit
import Foundation

// MARK: - Progress and outcome

/// Where a download has got to.
public enum ModelInstallPhase: Equatable, Sendable {
    case waiting
    /// Fraction complete, plus bytes received and expected.
    case downloading(fraction: Double, received: Int64, expected: Int64)
    case verifying
    case installed
    case failed(ModelInstallError)
    case cancelled
}

/// Why an install did not complete. Each case carries what the user needs to
/// decide what to do next, rather than a generic failure.
public enum ModelInstallError: Equatable, Sendable {
    /// Not enough free space. Both figures so the user can judge the gap.
    case insufficientDisk(neededBytes: Int64, freeBytes: Int64)
    /// This Mac does not have the memory to run the model. Downloading it would
    /// spend gigabytes on a file the ladder would then refuse to select, and on
    /// Apple silicon the memory is soldered, so this never becomes true later.
    case insufficientMemory(requirement: String)
    /// The transfer failed. Retryable.
    case transport(String)
    /// The file arrived but is the wrong size. Almost always a truncated
    /// transfer, so retrying is the right suggestion.
    case sizeMismatch(expected: Int64, actual: Int64)
    /// The bytes are not the model we expected. NOT retryable without
    /// investigation: something served different content.
    case digestMismatch
    /// Could not write into the app container.
    case storage(String)
    /// A request or redirect tried to leave the allowlisted hosts. Never
    /// retried silently: this is the failure that protects the network claim.
    case blockedHost(String)

    public var message: String {
        switch self {
        case let .insufficientDisk(needed, free):
            let n = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let f = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
            return "Not enough disk space. This model needs \(n) and there is \(f) free."
        case let .transport(detail):
            return "The download did not finish (\(detail)). You can try again."
        case let .sizeMismatch(expected, actual):
            let e = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            let a = ByteCountFormatter.string(fromByteCount: actual, countStyle: .file)
            return "The download is incomplete: expected \(e) but got \(a). Try again."
        case .digestMismatch:
            return "The downloaded file is not the model it should be, so it was "
                + "removed. Do not use it. Try again, and if it keeps happening "
                + "report it rather than working around it."
        case let .storage(detail):
            return "Could not save the model (\(detail))."
        case let .insufficientMemory(requirement):
            return "This Mac does not have enough memory to run this model. "
                + requirement
        case let .blockedHost(host):
            return "The download tried to contact \(host), which is not on LDA's "
                + "allowed list, so it was stopped. LDA only ever connects to "
                + "HuggingFace. Report this rather than working around it."
        }
    }

    /// Whether offering a Retry button makes sense.
    public var isRetryable: Bool {
        switch self {
        case .transport, .sizeMismatch, .insufficientDisk: return true
        case .digestMismatch, .storage, .blockedHost, .insufficientMemory: return false
        }
    }
}

// MARK: - Host allowlist

/// The only hosts this app will ever connect to.
///
/// A HuggingFace `/resolve/main/...` URL does not serve bytes: it answers 302 to
/// a content host (measured 2026-08-29: `us.aws.cdn.hf.co`), and that family
/// changes without notice. So the allowlist must be checked on EVERY redirect
/// hop, not just the first request. Checking only the initial URL would make the
/// published claim "connects only to HuggingFace" false the moment upstream
/// moves its CDN, and we would not find out.
public enum ModelHostAllowlist {

    /// Matched as an exact host or as a dot-prefixed suffix.
    public static let suffixes = ["huggingface.co", "hf.co"]

    /// Whether a host may be contacted.
    ///
    /// The dot prefix matters: a plain `hasSuffix` would accept
    /// `evil-huggingface.co`, which is a different registrable domain.
    public static func allows(host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return suffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

// MARK: - Installer

/// Downloads a model into the app container, verifies it, and removes it again.
///
/// The destination is `Application Support/LDA/Models/<tierID>/<fileName>`,
/// which the app owns outright, so no security-scoped bookmark is ever needed
/// for a downloaded model and it survives relaunches and reboots.
@MainActor
public final class ModelInstaller: NSObject, ObservableObject {

    /// Phase per tier id. Absent means idle.
    @Published public private(set) var phases: [String: ModelInstallPhase] = [:]

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var tierByTaskID: [Int: ModelTier] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        // Nothing about a document is involved here, but keep the request
        // surface minimal anyway: no cookies, no credentials, no caching of a
        // multi-gigabyte body.
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public override init() { super.init() }

    public func phase(for tier: ModelTier) -> ModelInstallPhase {
        phases[tier.id] ?? (ModelCatalog.isInstalled(tier) ? .installed : .waiting)
    }

    public func isBusy(_ tier: ModelTier) -> Bool {
        switch phase(for: tier) {
        case .downloading, .verifying: return true
        default: return false
        }
    }

    // MARK: Download

    /// Begin downloading a tier. No-op when it is already installed or running.
    ///
    /// Refuses a model this Mac cannot run. Apple silicon memory is soldered, so
    /// a blocked tier is blocked permanently on this machine: spending 13 GB of
    /// download on a file the ladder will never let the user select is a worse
    /// outcome than saying no up front.
    public func install(_ tier: ModelTier, installedGB: Double = MemoryGate.installedGB()) {
        guard !ModelCatalog.isInstalled(tier), tasks[tier.id] == nil else { return }

        if case .insufficientMemory = MemoryGate.availability(for: tier, installedGB: installedGB) {
            phases[tier.id] = .failed(
                .insufficientMemory(requirement: MemoryGate.requirementText(
                    for: tier, installedGB: installedGB
                ))
            )
            return
        }
        // URL(string:) is permissive: it accepts strings with spaces and any
        // scheme, so it alone is not validation. Require https and a real host,
        // otherwise a mistaken or tampered manifest entry could point the
        // installer at file:// or an arbitrary scheme.
        guard let url = URL(string: tier.sourceURL),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            phases[tier.id] = .failed(
                .storage("The download address for this model is not a valid https link.")
            )
            return
        }
        guard ModelHostAllowlist.allows(host: host) else {
            phases[tier.id] = .failed(.blockedHost(host))
            return
        }
        // Precheck space before starting a multi-gigabyte transfer. Require the
        // file plus headroom, because the download lands in a temporary file
        // and is then moved into place.
        if let free = freeSpaceBytes(), free < tier.sizeBytes + 1_000_000_000 {
            phases[tier.id] = .failed(
                .insufficientDisk(neededBytes: tier.sizeBytes + 1_000_000_000, freeBytes: free)
            )
            return
        }
        let task = session.downloadTask(with: url)
        tasks[tier.id] = task
        tierByTaskID[task.taskIdentifier] = tier
        phases[tier.id] = .downloading(fraction: 0, received: 0, expected: tier.sizeBytes)
        task.resume()
    }

    /// Cancel an in-flight download. The partial file is discarded by URLSession.
    public func cancel(_ tier: ModelTier) {
        guard let task = tasks[tier.id] else {
            phases[tier.id] = .cancelled
            return
        }
        // Drop the reverse mapping too. Leaving it meant a late callback from
        // the cancelled task could clear `tasks[tier.id]` for a NEWER download
        // of the same tier, which defeated the "already running" guard and let
        // two multi-gigabyte transfers of the same file run at once.
        tierByTaskID[task.taskIdentifier] = nil
        tasks[tier.id] = nil
        task.cancel()
        phases[tier.id] = .cancelled
    }

    /// Whether this callback belongs to the task currently owning the tier.
    /// A late callback from a superseded task must not touch live state.
    private func isCurrent(_ task: URLSessionTask, for tier: ModelTier) -> Bool {
        tasks[tier.id]?.taskIdentifier == task.taskIdentifier
    }

    // MARK: Remove

    /// Delete a downloaded model and report the space reclaimed.
    ///
    /// Returns nil when there was nothing to remove. A BUNDLED tier can never be
    /// removed: its file lives inside the app, so the caller must not offer it.
    @discardableResult
    public func remove(_ tier: ModelTier) -> Int64? {
        guard !ModelCatalog.isBundled(tier),
              let url = ModelCatalog.installedURL(for: tier),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init)
        do {
            try FileManager.default.removeItem(at: url)
            // Take the now-empty tier directory with it.
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            phases[tier.id] = .waiting
            return size
        } catch {
            phases[tier.id] = .failed(.storage(error.localizedDescription))
            return nil
        }
    }

    // MARK: Helpers

    private func freeSpaceBytes() -> Int64? {
        guard let root = ModelCatalog.modelsRoot() else { return nil }
        let probe = root.deletingLastPathComponent()
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Move a completed download into place, verifying size and digest.
    ///
    /// nonisolated because URLSession calls back off the main actor; the phase
    /// update hops back.
    fileprivate nonisolated func finish(tier: ModelTier, tempURL: URL) {
        let fm = FileManager.default
        do {
            let actual = Int64((try tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            guard actual == tier.sizeBytes else {
                try? fm.removeItem(at: tempURL)
                Task { @MainActor in
                    self.phases[tier.id] = .failed(
                        .sizeMismatch(expected: tier.sizeBytes, actual: actual)
                    )
                    self.tasks[tier.id] = nil
                }
                return
            }
            Task { @MainActor in self.phases[tier.id] = .verifying }

            // Fail CLOSED on a missing digest. Skipping verification when the
            // manifest has no hash would install an unverified multi-gigabyte
            // file into a redaction tool, and it would do it silently, which is
            // the worst combination. A tier without a digest must not ship, and
            // if one does, refusing it is the safe direction.
            guard !tier.sha256.isEmpty else {
                try? fm.removeItem(at: tempURL)
                Task { @MainActor in
                    self.phases[tier.id] = .failed(.storage(
                        "This model cannot be verified because no checksum was "
                        + "published for it, so it was not installed."
                    ))
                    self.tasks[tier.id] = nil
                }
                return
            }
            let digest = Self.sha256Hex(of: tempURL)
            guard digest?.caseInsensitiveCompare(tier.sha256) == .orderedSame else {
                try? fm.removeItem(at: tempURL)
                Task { @MainActor in
                    self.phases[tier.id] = .failed(.digestMismatch)
                    self.tasks[tier.id] = nil
                }
                return
            }

            guard let dest = ModelCatalog.installedURL(for: tier) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: tempURL, to: dest)
            Task { @MainActor in
                self.phases[tier.id] = .installed
                self.tasks[tier.id] = nil
            }
        } catch {
            try? fm.removeItem(at: tempURL)
            Task { @MainActor in
                self.phases[tier.id] = .failed(.storage(error.localizedDescription))
                self.tasks[tier.id] = nil
            }
        }
    }

    /// Streaming SHA-256, so a 13 GB file is never resident in memory.
    nonisolated static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - URLSession delegate

extension ModelInstaller: URLSessionDownloadDelegate {

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let id = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let tier = self.tierByTaskID[id] else { return }
            // Prefer the manifest size: a server that omits Content-Length
            // reports -1, which would render as a broken progress bar.
            let expected = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite : tier.sizeBytes
            let fraction = expected > 0
                ? min(1.0, Double(totalBytesWritten) / Double(expected)) : 0
            self.phases[tier.id] = .downloading(
                fraction: fraction, received: totalBytesWritten, expected: expected
            )
        }
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The temporary file is deleted when this returns, so move it out first.
        let staged = location.deletingLastPathComponent()
            .appendingPathComponent("lda-staged-\(UUID().uuidString)")
        try? FileManager.default.moveItem(at: location, to: staged)
        let id = downloadTask.taskIdentifier
        // A non-200 body still arrives here. Without this check a 404 page was
        // staged, failed the size check, and was reported as "incomplete, try
        // again", which is wrong for a permanent error. Checking the status
        // also settles the refused-redirect case deterministically: the 302
        // body arrives as a non-200 rather than racing the blockedHost report.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        Task { @MainActor in
            guard let tier = self.tierByTaskID[id],
                  self.isCurrent(downloadTask, for: tier) else {
                try? FileManager.default.removeItem(at: staged)
                return
            }
            self.tierByTaskID[id] = nil
            guard status == 200 else {
                try? FileManager.default.removeItem(at: staged)
                self.tasks[tier.id] = nil
                // A refused redirect already reported blockedHost; do not
                // overwrite that with a vaguer transport message.
                if case .failed(.blockedHost) = self.phases[tier.id] ?? .waiting { return }
                self.phases[tier.id] = .failed(.transport(
                    status == 0 ? "no response from the server"
                                : "the server answered \(status)"
                ))
                return
            }
            Task.detached { self.finish(tier: tier, tempURL: staged) }
        }
    }

    /// Re-check the allowlist on every redirect.
    ///
    /// Passing nil to the completion handler refuses the redirect. Without this
    /// the app would follow a 302 anywhere the upstream service pointed it, and
    /// the entitlement rationale in LDA.entitlements would be untrue.
    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let host = request.url?.host
        guard ModelHostAllowlist.allows(host: host) else {
            let id = task.taskIdentifier
            Task { @MainActor in
                guard let tier = self.tierByTaskID[id] else { return }
                self.tierByTaskID[id] = nil
                self.tasks[tier.id] = nil
                self.phases[tier.id] = .failed(.blockedHost(host ?? "unknown host"))
            }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    public nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let id = task.taskIdentifier
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        Task { @MainActor in
            guard let tier = self.tierByTaskID[id],
                  self.isCurrent(task, for: tier) else { return }
            self.tierByTaskID[id] = nil
            self.tasks[tier.id] = nil
            // A refused redirect has already set blockedHost, which is not
            // retryable. Do not downgrade it to a retryable transport error.
            if case .failed(.blockedHost) = self.phases[tier.id] ?? .waiting { return }
            self.phases[tier.id] = cancelled
                ? .cancelled
                : .failed(.transport(error.localizedDescription))
        }
    }
}
