import AppKit
import SwiftUI
import LDACore

enum LocalExportHistory {
    /// Called at the user-facing completion edge, with Matter identity captured
    /// before asynchronous work. A history failure never hides a successful file.
    static func record(_ urls: [URL], kind: VaultArtifactKind, workspaceID: UUID?, matterLabel: String?) -> String? {
        do {
            let history = ExportHistory()
            for url in urls {
                try history.record(ExportReceipt(fileURL: url, origin: .app, kind: kind,
                                                  workspaceID: workspaceID, matterLabel: matterLabel))
            }
            return nil
        } catch {
            return L10n.string("Export completed, but history could not be saved. Use this export's Reveal in Finder action.")
        }
    }
}

struct ExportHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @ObservedObject var session: SessionModel
    var selectedExportID: UUID? = nil
    @State private var receipts: [ExportReceipt] = []
    @State private var labels: [UUID: String] = [:]
    @State private var failure: String?
    @State private var loading = false
    @State private var refreshPending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                L10n.text("Export History").font(.title2.bold())
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                L10n.button("Refresh") { refresh() }.disabled(loading)
                L10n.button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            L10n.text("App and MCP exports. Each Reveal button opens the file recorded on that row.")
                .foregroundStyle(.secondary)
            if let failure { Text(verbatim: failure).foregroundStyle(.red) }
            if receipts.isEmpty && !loading && failure == nil {
                ContentUnavailableView {
                    L10n.label("No exports recorded", systemImage: "tray")
                } description: {
                    L10n.text("New App and MCP exports will appear here.")
                }
            } else {
                ScrollViewReader { proxy in
                    List(orderedReceipts) { receipt in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                if receipt.id == selectedExportID { L10n.text("Current MCP export").foregroundStyle(.tint).font(.headline) }
                                Text(verbatim: receipt.fileURL.lastPathComponent).font(.headline).textSelection(.enabled)
                                L10n.text("%@ · %@ · %@ · Completed",
                                    L10n.string(receipt.origin == .mcp ? "MCP" : "App", language: language) as NSString,
                                    receipt.format.uppercased() as NSString, kindName(receipt.kind) as NSString)
                                Text(verbatim: receipt.createdAt.formatted(
                                    Date.FormatStyle(date: .abbreviated, time: .standard).locale(language.locale)))
                                L10n.text("Matter: %@", matterName(receipt) as NSString)
                                Text(verbatim: receipt.exportID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Spacer()
                            L10n.button("Reveal in Finder") { reveal(receipt) }
                                .accessibilityIdentifier("revealExport-\(receipt.exportID)")
                        }
                        .padding(.vertical, 6)
                        .id(receipt.id)
                    }
                    .onChange(of: selectedExportID) { _, selected in
                        if let selected { proxy.scrollTo(selected, anchor: .top) }
                    }
                    .onChange(of: receipts.map(\.id)) { _, _ in
                        if let selectedExportID { proxy.scrollTo(selectedExportID, anchor: .top) }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 740, minHeight: 420)
        .onAppear { refresh() }
        .onChange(of: selectedExportID) { _, _ in refresh() }
    }

    private var orderedReceipts: [ExportReceipt] {
        guard let selectedExportID else { return receipts }
        return receipts.filter { $0.id == selectedExportID } + receipts.filter { $0.id != selectedExportID }
    }

    private func matterName(_ receipt: ExportReceipt) -> String {
        if let id = receipt.workspaceID { return labels[id] ?? receipt.matterLabel ?? id.uuidString }
        return receipt.matterLabel ?? L10n.string("No Matter", language: language)
    }

    private func kindName(_ kind: VaultArtifactKind) -> String {
        switch kind {
        case .original: return L10n.string("Original", language: language)
        case .redacted: return L10n.string("Redacted", language: language)
        case .restored: return L10n.string("Restored", language: language)
        }
    }

    private func refresh() {
        guard !loading else { refreshPending = true; return }
        loading = true
        failure = nil
        Task {
            do {
                receipts = try await Task.detached(priority: .userInitiated) { try ExportHistory().list() }.value
                if let matters = try? session.matterStore().list(protection: session.matterProtection()) {
                    labels = Dictionary(uniqueKeysWithValues: matters.metadata.map { ($0.id, $0.label) })
                }
            } catch {
                failure = LocalOperationFailure.message(for: error)
                    ?? L10n.string("Export history could not be opened. Check local file access, then refresh.", language: language)
            }
            loading = false
            if refreshPending { refreshPending = false; refresh() }
        }
    }

    private func reveal(_ receipt: ExportReceipt) {
        let url = receipt.resolvedURL()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Finder performs the reveal itself, including for a headless MCP outbox
        // outside the app sandbox. No document bytes need to enter this process.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
