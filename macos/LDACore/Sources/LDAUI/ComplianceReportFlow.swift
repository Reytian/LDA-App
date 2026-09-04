//
//  ComplianceReportFlow.swift
//  LDAUI
//
//  The Export Report and Open Report flows, as a view modifier the review
//  shell applies. Modelled on WorkspaceFlow, for the same reason: AppShell is
//  already the largest file in the module and these are self contained.
//
//  Both flows collect their destination BEFORE the passphrase, so a mistyped
//  passphrase can be corrected on the sheet instead of restarting the panels.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

// MARK: - Flow state

/// Owns which step of the report flow is on screen.
@MainActor
final class ComplianceReportFlowModel: ObservableObject {

    enum Stage: Equatable {
        case idle
        /// Collecting the shape and passphrase for an export into this folder.
        case exporting(URL)
        /// Collecting the passphrase that opens `source`, writing into
        /// `destination`.
        case opening(source: URL, destination: URL)
    }

    @Published var stage: Stage = .idle

    /// The shape the export sheet is on. Reset to the protected default every
    /// time the sheet closes, so a previous readable export cannot become the
    /// silent default of the next one.
    @Published var shape = ComplianceReportPresentation.defaultShape

    @Published var passphrase = ""
    @Published var confirmation = ""

    /// An error shown inside a sheet, so a mistyped passphrase can be
    /// corrected without starting over.
    @Published var sheetMessage: String?

    /// Bumped by the toolbar to raise the export panel.
    @Published var exportRequestToken = 0

    func requestExport() { exportRequestToken += 1 }

    func cancel() {
        stage = .idle
        resetInput()
    }

    func resetInput() {
        shape = ComplianceReportPresentation.defaultShape
        passphrase = ""
        confirmation = ""
        sheetMessage = nil
    }

    var isSheetPresented: Bool {
        switch stage {
        case .exporting, .opening: return true
        case .idle: return false
        }
    }
}

// MARK: - Flow modifier

/// Attaches the report export and open flows to a shell.
struct ComplianceReportFlow: ViewModifier {

    @ObservedObject var session: SessionModel
    @ObservedObject var flow: ComplianceReportFlowModel

    /// Where the flow reports its one-line outcome (the shell's banner).
    let report: (String?) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: sheetBinding) { sheet }
            .onChange(of: flow.exportRequestToken) { _, _ in presentExportPanel() }
            .onChange(of: session.pendingReportURL) { _, url in
                guard let url else { return }
                session.pendingReportURL = nil
                presentOpenDestinationPanel(source: url)
            }
    }

    @ViewBuilder
    private var sheet: some View {
        switch flow.stage {
        case .exporting:
            ComplianceReportExportSheet(flow: flow, onConfirm: confirmExport)
        case .opening:
            ComplianceReportOpenSheet(flow: flow, onConfirm: confirmOpen)
        case .idle:
            EmptyView()
        }
    }

    private var sheetBinding: Binding<Bool> {
        Binding(
            get: { flow.isSheetPresented },
            set: { if !$0 { flow.cancel() } }
        )
    }

    // MARK: - Export

    private func presentExportPanel() {
        // Same rule as ExportFlow: an export request that cannot run says why
        // rather than returning silently. See SaveAvailability.swift.
        let availability = session.complianceReportAvailability
        guard availability.isAvailable else {
            report(SaveAvailabilityPresentation.notice(availability))
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Choose a folder for the processing report.")
        panel.prompt = L10n.string("Export Here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        flow.resetInput()
        flow.stage = .exporting(dir)
    }

    private func confirmExport() {
        guard case .exporting(let dir) = flow.stage else { return }
        let protection = ComplianceReportPresentation.protection(
            for: flow.shape,
            passphrase: flow.passphrase
        )
        flow.stage = .idle
        flow.resetInput()

        let needsScope = dir.startAccessingSecurityScopedResource()
        defer { if needsScope { dir.stopAccessingSecurityScopedResource() } }
        do {
            let result = try session.exportComplianceReport(
                to: dir,
                generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
                protection: protection
            )
            report(ComplianceReportPresentation.summary(result))
        } catch {
            report(
                ComplianceReportPresentation.failure(error, action: "Exporting the report")
            )
        }
    }

    // MARK: - Open

    /// Ask where the readable copies should land before asking for the
    /// passphrase. Opening a report WRITES the names in the clear, so the user
    /// picks that destination knowingly.
    private func presentOpenDestinationPanel(source: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = L10n.string("Choose a folder for the readable copies of this report.")
        panel.prompt = L10n.string("Write Here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        flow.resetInput()
        flow.stage = .opening(source: source, destination: dir)
    }

    private func confirmOpen() {
        guard case .opening(let source, let destination) = flow.stage else { return }
        let passphrase = flow.passphrase
        flow.sheetMessage = nil

        let sourceScope = source.startAccessingSecurityScopedResource()
        let destinationScope = destination.startAccessingSecurityScopedResource()
        defer {
            if sourceScope { source.stopAccessingSecurityScopedResource() }
            if destinationScope { destination.stopAccessingSecurityScopedResource() }
        }
        do {
            let result = try session.openComplianceReport(
                at: source,
                passphrase: passphrase,
                writingInto: destination
            )
            flow.stage = .idle
            flow.resetInput()
            report(ComplianceReportPresentation.summary(result))
        } catch {
            // Stay on the sheet: a mistyped passphrase is the likely cause and
            // retyping it should not mean choosing both folders again.
            flow.sheetMessage = ComplianceReportPresentation
                .archiveErrorDescription(error)
                ?? DocumentErrorPresentation.describeOrFallback(error)
        }
    }
}

extension View {

    /// Attach the report export and open flows.
    func complianceReportFlow(
        session: SessionModel,
        flow: ComplianceReportFlowModel,
        report: @escaping (String?) -> Void
    ) -> some View {
        modifier(ComplianceReportFlow(session: session, flow: flow, report: report))
    }
}
