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
//  Neither dialog lets a keypress be the thing that discloses. Each puts the
//  fix first AND binds Return to it explicitly, because order is not a safety
//  property on its own: it is not established that SwiftUI's macOS
//  confirmationDialog binds Return to the first listed button, and the sibling
//  dialog in ClientMatterFlow lists a destructive action first with no
//  shortcut at all. So Return starts the download or opens Manage Models, the
//  button that proceeds carries no keypress, and Escape reaches Cancel. Where
//  no fix can be offered, Cancel owns Return instead: a Mac that can run no
//  model never reaches the scan gate, but it does reach the export gate, and
//  there the safe path still has to be the keypress.
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

    /// An Export for AI request waiting on the confirmation, and which
    /// disclosure it is about. nil when no export is parked.
    ///
    /// The reason travels with the request rather than being recomputed when
    /// the dialog renders, for the same reason a scan request carries its
    /// targets: the state it was read from can move while a dialog is up.
    @Published var pendingExport: ModelSetupPresentation.ExportGateReason?

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

    /// Whether any tier could run on this Mac at all. False on 8 GB and 12 GB,
    /// where the export gate carries no fix button because there is nothing
    /// the user could press that would change the answer. Apple silicon memory
    /// is soldered.
    let canRunAModel: Bool

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
                // The fix first, and Return bound to it rather than inferred
                // from the order: an accidental Return starts a download, never
                // a names-blind scan. The gate cannot fire on a Mac that can
                // run no model, so this button always exists here.
                Button(scanFixTitle) {
                    flow.pendingScan = nil
                    AISettings.recordModelSetupAnswer(.accepted)
                    onOpenModelManagement()
                }
                .keyboardShortcut(.defaultAction)
                Button(scan.proceed) {
                    let request = flow.pendingScan
                    flow.pendingScan = nil
                    if let request { onScan(request) }
                }
                L10n.button("Cancel", role: .cancel) { flow.pendingScan = nil }
                    .keyboardShortcut(.cancelAction)
            } message: {
                Text(verbatim: scan.message)
            }
            .confirmationDialog(
                Text(verbatim: export.title),
                isPresented: Binding(
                    get: { flow.pendingExport != nil },
                    set: { if !$0 { flow.pendingExport = nil } }
                ),
                titleVisibility: .visible
            ) {
                if canRunAModel {
                    Button(exportFixTitle) {
                        flow.pendingExport = nil
                        AISettings.recordModelSetupAnswer(.accepted)
                        onOpenModelManagement()
                    }
                    .keyboardShortcut(.defaultAction)
                }
                Button(export.proceed) {
                    flow.pendingExport = nil
                    onExport()
                }
                // Cancel takes Return on a Mac where no fix button rendered,
                // because the safe path has to be the keypress even with no
                // remedy to offer. Escape reaches a cancel-role button anyway,
                // so nothing is lost by spending its shortcut here.
                L10n.button("Cancel", role: .cancel) { flow.pendingExport = nil }
                    .keyboardShortcut(
                        exportDefault == .cancel ? .defaultAction : .cancelAction
                    )
            } message: {
                Text(verbatim: export.message)
            }
    }

    /// The pre-scan gate's first button: the download when it can start,
    /// otherwise the route into Manage Models where the checksum-verified
    /// import lives.
    private var scanFixTitle: String {
        canDownload
            ? ModelSetupPresentation.downloadButtonTitle(sizeDescription: sizeDescription)
            : L10n.string("Set Up a Model\u{2026}")
    }

    /// The export gate's first button.
    ///
    /// Manage Models rather than a download, because this gate does not mean
    /// "no model on this Mac". It fires whenever an exportable document's AI
    /// pass was asked for and did not finish, which includes a document that
    /// was scanned before an install landed and one where the pass ran and
    /// stopped short. Offering a 2.74 GB download to someone who already has
    /// the file would be wrong; Manage Models is true in every one of those
    /// states, and it is where both the download and the verified import live.
    private var exportFixTitle: String {
        L10n.string("Manage Models\u{2026}")
    }

    /// Which button Return reaches in the export dialog.
    private var exportDefault: ModelSetupPresentation.GateButton {
        ModelSetupPresentation.gateDefault(offersFix: canRunAModel)
    }

    private var scan: (title: String, message: String, proceed: String) {
        ModelSetupPresentation.scanConfirmation()
    }

    /// The parked reason, or the never-ran copy for the frame in which the
    /// dialog is dismissing and the reason has already been cleared.
    private var export: (title: String, message: String, proceed: String) {
        ModelSetupPresentation.exportConfirmation(reason: flow.pendingExport ?? .didNotRun)
    }
}

extension View {

    /// Attach the pre-scan and Export for AI model confirmations.
    func modelSetupFlow(
        flow: ModelSetupFlowModel,
        canDownload: Bool,
        canRunAModel: Bool,
        sizeDescription: String,
        onScan: @escaping (PendingScan) -> Void,
        onExport: @escaping () -> Void,
        onOpenModelManagement: @escaping () -> Void
    ) -> some View {
        modifier(
            ModelSetupFlow(
                flow: flow,
                canDownload: canDownload,
                canRunAModel: canRunAModel,
                sizeDescription: sizeDescription,
                onScan: onScan,
                onExport: onExport,
                onOpenModelManagement: onOpenModelManagement
            )
        )
    }
}
