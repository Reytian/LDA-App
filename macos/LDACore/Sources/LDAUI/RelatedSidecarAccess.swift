//
//  RelatedSidecarAccess.swift
//  LDAUI
//
//  Sidecar IO that survives App Sandbox. A Powerbox grant (open panel, save
//  panel, drop) covers the file the user chose and nothing next to it, so the
//  .ldamap written beside an exported .md, or read beside a chosen redacted
//  file, would be denied in the packaged app. macOS extends the grant to a
//  RELATED ITEM: a sibling with the same base name and an extension the app
//  declares in Info.plist with NSIsRelatedItemType, accessed through
//  NSFileCoordinator with a presenter whose primaryPresentedItemURL is the
//  chosen file. Every sidecar read and write in the app goes through here so
//  the rule exists once. In the unsandboxed dev binary the coordination is
//  harmless and the behavior is identical.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation
import LDACore

/// Coordinated access to a sidecar next to a user-chosen primary file.
enum RelatedSidecarAccess {

    /// Run `body` as a coordinated write of `sidecar`, the related item of
    /// `primary`. The URL handed to `body` is the one to write.
    @discardableResult
    static func write<T>(
        sidecar: URL,
        primary: URL,
        presenter: NSFilePresenter? = nil,
        _ body: (URL) throws -> T
    ) throws -> T {
        try perform(sidecar: sidecar, primary: primary, writing: true, presenter: presenter, body)
    }

    /// Run `body` as a coordinated read of `sidecar`, the related item of
    /// `primary`.
    static func read<T>(
        sidecar: URL,
        primary: URL,
        presenter: NSFilePresenter? = nil,
        _ body: (URL) throws -> T
    ) throws -> T {
        try perform(sidecar: sidecar, primary: primary, writing: false, presenter: presenter, body)
    }

    /// Whether the sidecar exists, checked inside the related-item grant: a
    /// plain stat of an unpermitted sibling reports "absent" in the sandbox.
    static func sidecarExists(_ sidecar: URL, primary: URL) -> Bool {
        (try? read(sidecar: sidecar, primary: primary) { url in
            FileManager.default.fileExists(atPath: url.path)
        }) ?? false
    }

    // MARK: - Coordination

    private static func perform<T>(
        sidecar: URL,
        primary: URL,
        writing: Bool,
        presenter explicitPresenter: NSFilePresenter?,
        _ body: (URL) throws -> T
    ) throws -> T {
        // The primary's own grant must be live while the related item is
        // touched. Balanced: a URL that needs no scope returns false.
        let scoped = primary.startAccessingSecurityScopedResource()
        defer { if scoped { primary.stopAccessingSecurityScopedResource() } }

        let presenter = explicitPresenter ?? RelatedSidecarPresenter(sidecar: sidecar, primary: primary)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }

        let coordinator = NSFileCoordinator(filePresenter: presenter)
        var coordinationError: NSError?
        var outcome: Result<T, Error>?
        let accessor: (URL) -> Void = { url in
            outcome = Result { try body(url) }
        }
        if writing {
            coordinator.coordinate(
                writingItemAt: sidecar,
                options: .forReplacing,
                error: &coordinationError,
                byAccessor: accessor
            )
        } else {
            coordinator.coordinate(
                readingItemAt: sidecar,
                options: [],
                error: &coordinationError,
                byAccessor: accessor
            )
        }
        if let coordinationError {
            throw DocumentIOError.unreadable(
                "File coordination failed for \(sidecar.lastPathComponent): "
                    + coordinationError.localizedDescription
            )
        }
        guard let outcome else {
            throw DocumentIOError.unreadable(
                "File coordination did not reach \(sidecar.lastPathComponent)."
            )
        }
        return try outcome.get()
    }
}

/// The presenter that names the chosen file as the sidecar's primary. Naming
/// it is what makes the sandbox extend the chosen file's grant to the sidecar.
final class RelatedSidecarPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let primaryPresentedItemURL: URL?

    /// A private serial queue: the coordinator may message the presenter
    /// while the caller waits on the main thread, and a main-queue presenter
    /// would deadlock there.
    let presentedItemOperationQueue: OperationQueue

    init(sidecar: URL, primary: URL) {
        presentedItemURL = sidecar
        primaryPresentedItemURL = primary
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "ai.openclaw.lda.related-sidecar"
        presentedItemOperationQueue = queue
    }
}
