//
//  ModelSetupFlow.swift
//  LDAUI
//
//  The two confirmations that stand between a model-less Mac and a scan that
//  does not look for names: the pre-scan gate and the Export for AI gate.
//
//  Kept out of AppShell, following WorkspaceFlow, ClientMatterFlow and
//  ExportFlow, for two reasons. That file was just cut down to 546 lines and a
//  sixth presentation modifier would start it growing again. And this window
//  has a documented case of two presentation modifiers on one view silently
//  never presenting (the two .fileImporter modifiers that broke Open), so each
//  flow owns its own attachment point rather than stacking.
//
//  Both dialogs offer the fix first, so an accidental Return spends bandwidth
//  and never confidentiality.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

// MARK: - Flow state

/// Which scan the user asked for, before the shell resolves which documents
/// that means. Both entry points are gated, so a Scan All over twelve
/// documents asks once and acknowledges all twelve.
enum ScanRequest: Equatable {
    case active
    case all
}

/// A scan request with its target documents fixed at the moment the user
/// asked.
///
/// The identity is snapshotted rather than re-derived on the way out of the
/// dialog. Deriving it twice, once when the gate fires and once inside the
/// confirm closure, made the acknowledgment and the dispatch depend on which
/// document happened to be active when the user answered. The dialog is
/// window-modal today, so that was probably unreachable; a request that
/// carries its own target cannot depend on the timing at all.
enum PendingScan: Equatable {
    case active(UUID)
    case all([UUID])

    /// The tray documents this request would scan.
    var targets: [UUID] {
        switch self {
        case .active(let id): return [id]
        case .all(let ids): return ids
        }
    }
}

/// Owns the parked scan or export request, and which tray documents have
/// already been acknowledged.
@MainActor
final class ModelSetupFlowModel: ObservableObject {

    /// A scan request waiting on the confirmation.
    @Published var pendingScan: PendingScan?

    /// An Export for AI request waiting on the confirmation.
    @Published var pendingExport = false

    /// The tray documents the user has already acknowledged scanning without
    /// a model.
    ///
    /// Session-only on purpose, and not @Published because no view renders it:
    /// a relaunch tells a returning user once per document rather than never
    /// again. A dialog whose text never changes on every press would train
    /// Scan then Return as one gesture, and that reflex then fires through the
    /// genuinely different unresolved-seam advisory, which renders in the same
    /// region.
    var confirmedIDs: Set<UUID> = []
}

// MARK: - Flow modifier

/// Attaches the pre-scan and Export for AI confirmations to a shell.
struct ModelSetupFlow: ViewModifier {

    @ObservedObject var flow: ModelSetupFlowModel

    /// Whether a download can start on this Mac right now. False under offline
    /// mode, which may be MDM-forced, so the dialog's first button becomes the
    /// route that still leads somewhere reachable.
    let canDownload: Bool

    /// The Quick tier's download size, from Models.json.
    let sizeDescription: String

    /// Run the parked scan. The shell re-resolves the model path first.
    let onScan: (PendingScan) -> Void

    /// Run the parked Export for AI.
    let onExport: () -> Void

    /// Open Manage Models, which carries every download gate.
    let onOpenModelManagement: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                Text(verbatim: scan.title),
                isPresented: Binding(
                    get: { flow.pendingScan != nil },
                    set: { if !$0 { flow.pendingScan = nil } }
                ),
                titleVisibility: .visible
            ) {
                // The fix first: an accidental Return starts a download rather
                // than a names-blind scan.
                Button(fixTitle) {
                    flow.pendingScan = nil
                    AISettings.recordModelSetupAnswer(.accepted)
                    onOpenModelManagement()
                }
                Button(scan.proceed) {
                    let request = flow.pendingScan
                    flow.pendingScan = nil
                    if let request { onScan(request) }
                }
                Button("Cancel", role: .cancel) { flow.pendingScan = nil }
            } message: {
                Text(verbatim: scan.message)
            }
            .confirmationDialog(
                Text(verbatim: export.title),
                isPresented: $flow.pendingExport,
                titleVisibility: .visible
            ) {
                Button(export.proceed) {
                    flow.pendingExport = false
                    onExport()
                }
                Button("Cancel", role: .cancel) { flow.pendingExport = false }
            } message: {
                Text(verbatim: export.message)
            }
    }

    /// The first button: the download when it can start, otherwise the route
    /// into Manage Models where the checksum-verified import lives.
    private var fixTitle: String {
        canDownload
            ? ModelSetupPresentation.downloadButtonTitle(sizeDescription: sizeDescription)
            : L10n.string("Set Up a Model\u{2026}")
    }

    private var scan: (title: String, message: String, proceed: String) {
        ModelSetupPresentation.scanConfirmation()
    }

    private var export: (title: String, message: String, proceed: String) {
        ModelSetupPresentation.exportConfirmation()
    }
}

extension View {

    /// Attach the pre-scan and Export for AI model confirmations.
    func modelSetupFlow(
        flow: ModelSetupFlowModel,
        canDownload: Bool,
        sizeDescription: String,
        onScan: @escaping (PendingScan) -> Void,
        onExport: @escaping () -> Void,
        onOpenModelManagement: @escaping () -> Void
    ) -> some View {
        modifier(
            ModelSetupFlow(
                flow: flow,
                canDownload: canDownload,
                sizeDescription: sizeDescription,
                onScan: onScan,
                onExport: onExport,
                onOpenModelManagement: onOpenModelManagement
            )
        )
    }
}
