import AppKit
import UniformTypeIdentifiers
import LDACore

/// Native, local-only controls. No file URL or document content enters stdio.
enum MCPLocalHandoff {
    private static var canPresent: Bool {
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { return false }
        #endif
        return Thread.isMainThread
    }

    /// Let a newly installed sandboxed app establish its container before the
    /// shared receipt directory is chosen. Existing GUI sessions are untouched.
    static func prepareExportApp(configuredURL: URL?) -> URL? {
        guard canPresent, let url = configuredURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.haotianyi.LDA") else { return nil }
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.haotianyi.LDA").contains(where: { $0.bundleURL == url }) { return url }
        let state = LaunchState()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
            state.lock.withLock { state.finished = true; state.ready = app != nil }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !state.lock.withLock({ state.finished }), ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return state.lock.withLock { state.ready ? url : nil }
    }

    private final class LaunchState: @unchecked Sendable {
        let lock = NSLock()
        var ready = false
        var finished = false
    }

    static func presentExport(_ receipt: ExportReceipt, historySaved: Bool, appURL: URL? = nil) -> String {
        guard canPresent else { return "unavailable" }
        if historySaved, let app = appURL {
            // Open the receipt in the GUI without holding up a successful MCP
            // response waiting for the human to dismiss a completion dialog.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([receipt.localActionURL], withApplicationAt: app, configuration: configuration)
            return "requested"
        }
        activate()
        let alert = NSAlert()
        alert.messageText = "LDA: MCP export completed"
        alert.informativeText = "\(receipt.fileURL.lastPathComponent)\n\(receipt.format.uppercased()) · \(receipt.kind.rawValue.capitalized)\n\(receipt.createdAt.formatted())\n"
            + (historySaved ? "This exact export is also in LDA Export History." : "History could not be saved. Reveal this export now to keep a local copy.")
        alert.addButton(withTitle: "Reveal in Finder")
        alert.addButton(withTitle: "Done")
        let result = run(alert, timeout: 120)
        if result == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([receipt.fileURL])
            return "revealed"
        }
        return result == .abort ? "timed_out" : "shown"
    }

    static func selectEditedDocument(source: VaultEntry, filename: String?) throws -> URL? {
        guard canPresent else { throw MCPVaultToolError.localHandoffUnavailable }
        activate()
        let panel = NSOpenPanel()
        panel.title = "LDA: Import edited redacted document"
        panel.message = "Source: \(filename ?? source.handle)\nMatter: \(source.workspaceID?.uuidString ?? "No Matter")\n"
            + "Choose the edited REDACTED copy for this source. Its placeholders will use this source's mapping. "
            + "For Word, accept or reject all tracked changes and save first. LDA refuses unresolved revisions and preserves the Word package."
        panel.prompt = "Import for This Source"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let formats = source.format == "docx" ? ["docx"] : ["docx", "txt", "md"]
        panel.allowedContentTypes = formats.compactMap { UTType(filenameExtension: $0) }
        let timer = Timer(timeInterval: 600, repeats: false) { _ in panel.cancel(nil) }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); panel.orderOut(nil) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func runImport(_ operation: @escaping (@escaping (VaultStagingPhase) throws -> Void) throws -> VaultEntry) throws -> VaultEntry {
        guard canPresent else { throw MCPVaultToolError.localHandoffUnavailable }
        let alert = NSAlert()
        alert.messageText = "LDA: Importing edited document"
        alert.informativeText = "Preparing the local Word handoff..."
        let cancel = alert.addButton(withTitle: "Cancel")
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 280, height: 16))
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        alert.accessoryView = spinner
        let state = ImportState()
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try operation { try state.advance($0) } }
            state.finish(result)
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
            let snapshot = state.snapshot()
            alert.informativeText = snapshot.message + "\nElapsed: \(Int(Date().timeIntervalSince(started))) seconds."
                + (Date().timeIntervalSince(started) > 20 ? "\nStill working locally. A delay alone does not indicate an authentication problem." : "")
            cancel.isEnabled = snapshot.canCancel
            if snapshot.finished { NSApplication.shared.abortModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); alert.window.orderOut(nil) }
        // Cancellation waits for the worker to acknowledge it before returning.
        // A registration already in progress wins, and is reported as completed.
        while !state.snapshot().finished {
            if alert.runModal() == .alertFirstButtonReturn { state.cancel() }
        }
        return try state.result().get()
    }

    private static func activate() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private static func run(_ alert: NSAlert, timeout: TimeInterval) -> NSApplication.ModalResponse {
        let timer = Timer(timeInterval: timeout, repeats: false) { _ in NSApplication.shared.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        defer { timer.invalidate(); alert.window.orderOut(nil) }
        return alert.runModal()
    }

    private final class ImportState: @unchecked Sendable {
        let lock = NSLock()
        var cancelled = false
        var registering = false
        var message = "Preparing the local import..."
        var outcome: Result<VaultEntry, Error>?

        func advance(_ phase: VaultStagingPhase) throws {
            try lock.withLock {
                if cancelled { throw DocumentVaultError.stagingCancelled }
                registering = phase == .registering
                message = phase.message
            }
        }
        func cancel() {
            lock.withLock {
                if !registering { cancelled = true; message = "Cancelling safely; waiting for the current local step to finish..." }
            }
        }
        func finish(_ result: Result<VaultEntry, Error>) { lock.withLock { outcome = result } }
        func result() -> Result<VaultEntry, Error> { lock.withLock { outcome! } }
        func snapshot() -> (message: String, canCancel: Bool, finished: Bool) {
            lock.withLock { (message, !registering && !cancelled, outcome != nil) }
        }
    }
}
