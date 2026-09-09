import SwiftUI
import LDACore

/// Runs inside the existing LDA GUI, so protected Matter labels never reach the MCP host.
public struct MCPWorkspacePicker: View {
    public let request: MCPWorkspaceRequest
    @ObservedObject private var session: SessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var matters: [MatterMetadata] = []
    @State private var selected: UUID?
    @State private var loaded = false
    @State private var failed = false

    public init(request: MCPWorkspaceRequest, session: SessionModel) {
        self.request = request
        self.session = session
        _selected = State(initialValue: request.currentWorkspaceID)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            L10n.text("Choose a Matter for this document")
                .font(.title2)
            L10n.text("New redacted and restored versions inherit this choice. Matter names stay on this Mac.")
                .foregroundStyle(.secondary)
            Text(request.handle).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let hint = request.workspaceHint {
                L10n.text("Requested workspace: %@", hint as NSString)
                    .font(.callout)
            }
            if failed {
                L10n.text("Your Matters could not be unlocked. Cancel and unlock them in LDA, then try again.")
                    .foregroundStyle(.red)
            } else if loaded {
                Picker(selection: $selected) {
                    L10n.text("No Matter").tag(Optional<UUID>.none)
                    ForEach(matters) { matter in Text(matter.label).tag(Optional(matter.id)) }
                } label: { L10n.text("Matter") }
                if matters.isEmpty {
                    L10n.text("Create a Matter in LDA to organize this document, then try again.")
                        .foregroundStyle(.secondary)
                }
            } else { ProgressView() }
            HStack {
                Spacer()
                Button { finish(confirmed: false) } label: { L10n.text("Cancel") }
                    .keyboardShortcut(.cancelAction)
                Button { finish(confirmed: true) } label: { L10n.text("Save Association") }
                    .disabled(!loaded || failed)
            }
        }
        .padding(28)
        .frame(width: 520)
        .interactiveDismissDisabled()
        .task { load() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now in
            if request.isExpired(at: now) { dismiss() }
        }
    }

    private func load() {
        do {
            let metadata = try session.matterMetadata()
            let clients = try session.resolvedClientLabels()
            let history = try session.recordStore().resolve(protection: session.recordProtection())
            guard metadata.unreadableCount == 0, clients.unreadableCount == 0, history.unreadableCount == 0 else {
                failed = true; return
            }
            let summaries = MatterWorkspacePresentation.summaries(clientLabels: clients.labels, records: history.records, metadata: metadata.metadata)
            let store = try session.matterStore()
            matters = try summaries.filter { summary in
                !summary.isArchived || metadata.metadata.contains { $0.id == selected && $0.label == summary.label }
            }.map { try store.ensure(label: $0.label, protection: session.matterProtection()) }
            if let selected, !matters.contains(where: { $0.id == selected }) { self.selected = nil }
            if let hint = request.workspaceHint {
                let matches = matters.filter { $0.label.caseInsensitiveCompare(hint) == .orderedSame }
                if matches.count == 1 { selected = matches[0].id }
            }
            loaded = true
        } catch { failed = true }
    }

    private func finish(confirmed: Bool) {
        guard !request.isExpired() else { dismiss(); return }
        do {
            try MCPWorkspaceBridge.reply(MCPWorkspaceReply(requestID: request.id, confirmed: confirmed, workspaceID: selected))
            dismiss()
        } catch { failed = true }
    }
}
