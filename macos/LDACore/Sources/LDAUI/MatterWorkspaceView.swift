//
//  MatterWorkspaceView.swift
//  LDAUI
//
//  A local workspace assembled from existing client mappings, encrypted
//  value-free session records, and encrypted organization metadata.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

struct MatterWorkspaceView: View {
    @ObservedObject private var session: SessionModel

    let isActive: Bool
    let onOpenDestination: (MatterWorkspaceDestination) -> Void

    @State private var summaries: [MatterSummary] = []
    @State private var records: [SessionRecord] = []
    @State private var metadata: [MatterMetadata] = []
    @State private var selectedMatterID: String?
    @State private var searchText = ""
    @State private var scope: MatterWorkspaceScope = .active
    @State private var clientListLoadFailed = false
    @State private var historyLoadFailed = false
    @State private var metadataLoadFailed = false
    @State private var isNewMatterPresented = false
    @State private var matterToRename: MatterSummary?
    @State private var pendingTransition: PendingMatterTransition?
    @State private var pendingArchive: PendingMatterArchive?
    @State private var workspaceError: String?

    init(
        session: SessionModel,
        isActive: Bool,
        onOpenDestination: @escaping (MatterWorkspaceDestination) -> Void
    ) {
        self.session = session
        self.isActive = isActive
        self.onOpenDestination = onOpenDestination
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            detail
        }
        .background(CounselTheme.appSurface)
        .toolbar {
            if isActive {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isNewMatterPresented = true
                    } label: {
                        Label("New Matter", systemImage: "plus")
                    }
                    .help("Start a protected workflow for a new client or matter")
                }
            }
        }
        .sheet(isPresented: $isNewMatterPresented) {
            NewMatterSheet { label in
                requestTransition(to: label, destination: .anonymize)
            }
        }
        .sheet(item: $matterToRename) { summary in
            RenameMatterSheet(currentLabel: summary.label) { newLabel in
                try rename(summary, to: newLabel)
            }
        }
        .confirmationDialog(
            "Close current work?",
            isPresented: Binding(
                get: { pendingTransition != nil },
                set: { if !$0 { pendingTransition = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingTransition {
                Button("Close Active Work and Switch", role: .destructive) {
                    do {
                        if try session.selectMatter(
                            pendingTransition.label,
                            discardingDocuments: true
                        ) {
                            onOpenDestination(pendingTransition.destination)
                        }
                    } catch {
                        workspaceError = error.localizedDescription
                    }
                    self.pendingTransition = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingTransition = nil
            }
        } message: {
            Text("Switching matters closes the documents and any unfinished restore context in this window. Saved files are not affected.")
        }
        .confirmationDialog(
            "Archive \(pendingArchive?.summary.label ?? "matter")?",
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingArchive {
                Button(
                    pendingArchive.discardsActiveWork
                        ? "Close Active Work and Archive"
                        : "Archive Matter",
                    role: pendingArchive.discardsActiveWork ? .destructive : nil
                ) {
                    archive(pendingArchive)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingArchive = nil
            }
        } message: {
            if pendingArchive?.discardsActiveWork == true {
                Text("Archiving closes the documents and unfinished restore context in this window. Saved files are not affected, and the matter can be restored from Archived.")
            } else {
                Text("The matter will move out of Active. Its encrypted identities and history are kept and can be restored later.")
            }
        }
        .alert(
            "Could not update matter",
            isPresented: Binding(
                get: { workspaceError != nil },
                set: { if !$0 { workspaceError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(workspaceError ?? "Please try again.")
        }
        .onAppear {
            if isActive { reload() }
        }
        .onChange(of: isActive) { _, active in
            if active { reload() }
        }
        .onChange(of: scope) { _, _ in
            selectFirstVisibleMatter()
        }
    }

    private var visibleSummaries: [MatterSummary] {
        MatterWorkspacePresentation.summaries(summaries, in: scope)
    }

    private var filteredSummaries: [MatterSummary] {
        guard !searchText.isEmpty else { return visibleSummaries }
        return visibleSummaries.filter {
            $0.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var loadFailed: Bool {
        clientListLoadFailed || historyLoadFailed || metadataLoadFailed
    }

    private var selectedSummary: MatterSummary? {
        guard let selectedMatterID else { return nil }
        return summaries.first { $0.id == selectedMatterID }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                    Text("Matters")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Text(summaries.isEmpty ? "Local workspaces" : "\(summaries.count) local workspaces")
                        .font(.caption)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
                Spacer()
                Button {
                    isNewMatterPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Matter")
            }
            .padding(.horizontal, CounselTheme.Space.lg)
            .padding(.vertical, CounselTheme.Space.md)

            Picker("Matter status", selection: $scope) {
                Text("Active \(activeCount)").tag(MatterWorkspaceScope.active)
                Text("Archived \(archivedCount)").tag(MatterWorkspaceScope.archived)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, CounselTheme.Space.md)
            .padding(.bottom, CounselTheme.Space.md)

            Divider()

            if filteredSummaries.isEmpty {
                VStack(spacing: CounselTheme.Space.md) {
                    Spacer()
                    Image(systemName: emptySidebarIcon)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(CounselTheme.textSecondary)
                    Text(emptySidebarTitle)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    if searchText.isEmpty {
                        Text(emptySidebarMessage)
                            .font(.caption)
                            .foregroundStyle(CounselTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(CounselTheme.Space.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredSummaries, selection: $selectedMatterID) { summary in
                    MatterSidebarRow(summary: summary)
                        .tag(summary.id)
                        .contextMenu {
                            Button {
                                matterToRename = summary
                            } label: {
                                Label("Rename Matter", systemImage: "pencil")
                            }
                            .disabled(loadFailed)

                            Divider()

                            Button {
                                requestArchiveToggle(summary)
                            } label: {
                                Label(
                                    summary.isArchived ? "Restore to Active" : "Archive Matter",
                                    systemImage: summary.isArchived
                                        ? "arrow.uturn.backward.circle"
                                        : "archivebox"
                                )
                            }
                            .disabled(metadataLoadFailed)
                        }
                }
                .listStyle(.sidebar)
            }

            if loadFailed {
                Divider()
                HStack(alignment: .top, spacing: CounselTheme.Space.sm) {
                    Image(systemName: "exclamationmark.lock")
                        .foregroundStyle(CounselTheme.textSecondary)
                    VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                        Text(loadFailureTitle)
                            .font(.caption.weight(.semibold))
                        Button("Try Again") { reload() }
                            .font(.caption)
                            .buttonStyle(.link)
                    }
                }
                .foregroundStyle(CounselTheme.textSecondary)
                .padding(CounselTheme.Space.md)
            }
        }
        .background(CounselTheme.appSurface)
        .searchable(text: $searchText, placement: .sidebar, prompt: "Find a matter")
    }

    @ViewBuilder
    private var detail: some View {
        if let summary = selectedSummary {
            MatterDetailView(
                summary: summary,
                records: MatterWorkspacePresentation.records(
                    for: summary.label,
                    from: records,
                    metadata: metadata
                ),
                historyAvailable: !historyLoadFailed,
                onAnonymize: { open(summary, destination: .anonymize) },
                onRestore: { open(summary, destination: .restore) },
                onRename: { matterToRename = summary },
                onArchiveToggle: { requestArchiveToggle(summary) }
            )
        } else {
            MatterWorkspaceEmptyView(scope: scope) {
                isNewMatterPresented = true
            }
        }
    }

    private func open(_ summary: MatterSummary, destination: MatterWorkspaceDestination) {
        requestTransition(to: summary.label, destination: destination)
    }

    private func requestTransition(
        to label: String,
        destination: MatterWorkspaceDestination
    ) {
        do {
            if try session.selectMatter(label) {
                onOpenDestination(destination)
            } else {
                pendingTransition = PendingMatterTransition(
                    label: label,
                    destination: destination
                )
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    private func reload() {
        var clientLabels: [String] = []
        do {
            let resolution = try session.resolvedClientLabels()
            clientLabels = resolution.labels
            clientListLoadFailed = resolution.unreadableCount > 0
        } catch {
            clientListLoadFailed = true
        }
        do {
            let resolution = try session.recordStore().resolve(
                protection: session.recordProtection()
            )
            records = resolution.records
            historyLoadFailed = resolution.unreadableCount > 0
        } catch {
            records = []
            historyLoadFailed = true
        }
        do {
            let resolution = try session.matterMetadata()
            metadata = resolution.metadata
            metadataLoadFailed = resolution.unreadableCount > 0
        } catch {
            metadata = []
            metadataLoadFailed = true
        }

        summaries = MatterWorkspacePresentation.summaries(
            clientLabels: clientLabels,
            records: records,
            metadata: metadata
        )

        if let selectedMatterID,
           visibleSummaries.contains(where: { $0.id == selectedMatterID }) {
            return
        }

        if let activeLabel = session.clientLabel {
            let activeID = MatterWorkspacePresentation
                .summaries(clientLabels: [activeLabel], records: [], metadata: metadata)
                .first?.id
            selectedMatterID = visibleSummaries.first { $0.id == activeID }?.id
        }
        selectFirstVisibleMatter()
    }

    private var loadFailureTitle: String {
        let failureCount = [clientListLoadFailed, historyLoadFailed, metadataLoadFailed]
            .filter { $0 }
            .count
        if failureCount > 1 {
            return "Some workspace data is locked"
        }
        if clientListLoadFailed {
            return "Saved client list is locked"
        }
        if historyLoadFailed {
            return "Recent activity is locked"
        }
        return "Matter organization is locked"
    }

    private var activeCount: Int {
        MatterWorkspacePresentation.summaries(summaries, in: .active).count
    }

    private var archivedCount: Int {
        MatterWorkspacePresentation.summaries(summaries, in: .archived).count
    }

    private var emptySidebarIcon: String {
        if !searchText.isEmpty { return "magnifyingglass" }
        return scope == .archived ? "archivebox" : "briefcase"
    }

    private var emptySidebarTitle: String {
        if !searchText.isEmpty { return "No matching matters" }
        return scope == .archived ? "No archived matters" : "No matters yet"
    }

    private var emptySidebarMessage: String {
        scope == .archived
            ? "Archived matters stay encrypted here until you restore them."
            : "Start one to keep its protected handoffs together."
    }

    private func selectFirstVisibleMatter() {
        if let selectedMatterID,
           visibleSummaries.contains(where: { $0.id == selectedMatterID }) {
            return
        }
        selectedMatterID = visibleSummaries.first?.id
    }

    private func rename(_ summary: MatterSummary, to newLabel: String) throws {
        try session.renameMatter(from: summary.label, to: newLabel)
        selectedMatterID = MatterWorkspacePresentation.cleanedLabel(newLabel)
        reload()
    }

    private func requestArchiveToggle(_ summary: MatterSummary) {
        if summary.isArchived {
            do {
                try session.setMatterArchived(summary.label, isArchived: false)
                scope = .active
                selectedMatterID = summary.id
                reload()
            } catch {
                workspaceError = error.localizedDescription
            }
            return
        }
        let hasParkedWork: Bool
        do {
            hasParkedWork = try session.hasParkedMatterWork(summary.label)
        } catch {
            workspaceError = error.localizedDescription
            return
        }
        pendingArchive = PendingMatterArchive(
            summary: summary,
            discardsActiveWork: (
                session.clientLabel == summary.label && session.hasActiveMatterWork
            ) || hasParkedWork
        )
    }

    private func archive(_ pending: PendingMatterArchive) {
        do {
            let archived = try session.setMatterArchived(
                pending.summary.label,
                isArchived: true,
                discardingDocuments: pending.discardsActiveWork
            )
            if archived {
                selectedMatterID = nil
                reload()
            }
        } catch {
            workspaceError = error.localizedDescription
        }
        pendingArchive = nil
    }
}

private struct MatterSidebarRow: View {
    let summary: MatterSummary

    var body: some View {
        HStack(spacing: CounselTheme.Space.sm) {
            Image(systemName: summary.isArchived ? "archivebox.fill" : "briefcase.fill")
                .foregroundStyle(CounselTheme.inkAccent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.label)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CounselTheme.textPrimary)
                    .lineLimit(1)
                Text(activityLine)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, CounselTheme.Space.xs)
    }

    private var activityLine: String {
        guard let stamp = summary.lastActivityISO8601 else {
            return "Ready for first handoff"
        }
        return "Updated \(MatterDateFormatter.relative(stamp))"
    }
}

private struct MatterDetailView: View {
    let summary: MatterSummary
    let records: [SessionRecord]
    let historyAvailable: Bool
    let onAnonymize: () -> Void
    let onRestore: () -> Void
    let onRename: () -> Void
    let onArchiveToggle: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CounselTheme.Space.xl) {
                header
                metricGrid
                Divider()
                activitySection
                privacyNote
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CounselTheme.paper)
        .navigationTitle(summary.label)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.md) {
            HStack(alignment: .top, spacing: CounselTheme.Space.lg) {
                VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                    HStack(spacing: CounselTheme.Space.sm) {
                        Text("MATTER WORKSPACE")
                            .font(.caption.weight(.semibold))
                            .tracking(0.8)
                            .foregroundStyle(CounselTheme.inkAccent)
                        if summary.isArchived {
                            Label("Archived", systemImage: "archivebox.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CounselTheme.textSecondary)
                        }
                    }
                    Text(summary.label)
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundStyle(CounselTheme.textPrimary)
                    if let stamp = summary.lastActivityISO8601 {
                        Text("Last activity \(MatterDateFormatter.full(stamp))")
                            .font(.callout)
                            .foregroundStyle(CounselTheme.textSecondary)
                    } else {
                        Text("No protected handoffs recorded yet.")
                            .font(.callout)
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                }
                Spacer()
                Menu {
                    Button(action: onRename) {
                        Label("Rename Matter", systemImage: "pencil")
                    }
                    Divider()
                    Button(action: onArchiveToggle) {
                        Label(
                            summary.isArchived ? "Restore to Active" : "Archive Matter",
                            systemImage: summary.isArchived
                                ? "arrow.uturn.backward.circle"
                                : "archivebox"
                        )
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .help("Matter actions")
            }

            if summary.isArchived {
                HStack(spacing: CounselTheme.Space.md) {
                    Button(action: onArchiveToggle) {
                        Label("Restore to Active", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    Text("Restore this matter before starting another protected handoff.")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
            } else {
                HStack(spacing: CounselTheme.Space.md) {
                    Button(action: onAnonymize) {
                        Label("Anonymize Documents", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)

                    Button(action: onRestore) {
                        Label("Restore AI Answer", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var metricGrid: some View {
        HStack(spacing: CounselTheme.Space.md) {
            MatterMetricCard(
                value: summary.sessionCount,
                label: summary.sessionCount == 1 ? "Handoff" : "Handoffs",
                systemImage: "arrow.right.doc.on.clipboard"
            )
            MatterMetricCard(
                value: summary.documentCount,
                label: summary.documentCount == 1 ? "Document" : "Documents",
                systemImage: "doc.on.doc"
            )
            MatterMetricCard(
                value: summary.protectedValueCount,
                label: summary.protectedValueCount == 1 ? "Known Identity" : "Known Identities",
                systemImage: "person.badge.shield.checkmark"
            )
            MatterMetricCard(
                value: summary.restoreCount,
                label: summary.restoreCount == 1 ? "Restore" : "Restores",
                systemImage: "arrow.uturn.backward"
            )
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.md) {
            Text("Recent activity")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)

            if !historyAvailable {
                Label(
                    "Some recent activity could not be unlocked. Readable handoffs remain below.",
                    systemImage: "exclamationmark.lock"
                )
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
            }

            if records.isEmpty, historyAvailable {
                VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                    Text("Start with an anonymized handoff")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Text("After Copy for AI, this page will show the documents and counts for the handoff.")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
                .padding(CounselTheme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CounselTheme.raised)
                .clipShape(RoundedRectangle(cornerRadius: CounselTheme.Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: CounselTheme.Radius.md)
                        .stroke(CounselTheme.hairline, lineWidth: 1)
                }
            } else if !records.isEmpty {
                LazyVStack(spacing: CounselTheme.Space.sm) {
                    ForEach(records.prefix(8)) { record in
                        MatterActivityRow(record: record)
                    }
                }
            }
        }
    }

    private var privacyNote: some View {
        Label {
            Text("Matter names, archive status, counts, and document names are stored in encrypted local records. "
                + "Protected values and document contents are never stored here.")
        } icon: {
            Image(systemName: "lock.laptopcomputer")
        }
        .font(.caption)
        .foregroundStyle(CounselTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MatterMetricCard: View {
    let value: Int
    let label: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.sm) {
            Image(systemName: systemImage)
                .foregroundStyle(CounselTheme.inkAccent)
            Text("\(value)")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(CounselTheme.textPrimary)
            Text(label)
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
        }
        .padding(CounselTheme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CounselTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: CounselTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: CounselTheme.Radius.md)
                .stroke(CounselTheme.hairline, lineWidth: 1)
        }
    }
}

private struct MatterActivityRow: View {
    let record: SessionRecord

    var body: some View {
        HStack(alignment: .top, spacing: CounselTheme.Space.md) {
            Image(systemName: "doc.text")
                .foregroundStyle(CounselTheme.inkAccent)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                HStack {
                    Text(MatterDateFormatter.full(record.createdAtISO8601))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Spacer()
                    Text("\(record.protectedValueCount) protected")
                        .font(.caption)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
                Text(documentLine)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .lineLimit(2)
                Text(restoreLine)
                    .font(.caption)
                    .foregroundStyle(recordFlagCount > 0 ? CounselTheme.danger : CounselTheme.textSecondary)
            }
        }
        .padding(CounselTheme.Space.lg)
        .background(CounselTheme.raised)
        .clipShape(RoundedRectangle(cornerRadius: CounselTheme.Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: CounselTheme.Radius.md)
                .stroke(CounselTheme.hairline, lineWidth: 1)
        }
    }

    private var documentLine: String {
        let names = record.documents.map(\.name)
        guard !names.isEmpty else { return "No document names recorded" }
        return names.joined(separator: ", ")
    }

    private var recordFlagCount: Int {
        record.restoreEvents.reduce(0) {
            $0 + $1.orphanCount + $1.suspectCount + $1.ambiguousCount
        }
    }

    private var restoreLine: String {
        guard !record.restoreEvents.isEmpty else { return "Awaiting restored result" }
        let restored = record.restoreEvents.reduce(0) { $0 + $1.restoredCount }
        if recordFlagCount > 0 {
            return "\(restored) values restored, \(recordFlagCount) flagged for review"
        }
        return "\(restored) values restored"
    }
}

private struct MatterWorkspaceEmptyView: View {
    let scope: MatterWorkspaceScope
    let onNewMatter: () -> Void

    var body: some View {
        VStack(spacing: CounselTheme.Space.lg) {
            Image(systemName: scope == .archived ? "archivebox" : "briefcase")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent)
            VStack(spacing: CounselTheme.Space.sm) {
                Text(scope == .archived ? "No archived matters" : "Keep each matter in context")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if scope == .active {
                Button(action: onNewMatter) {
                    Label("Start a New Matter", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CounselTheme.paper)
    }

    private var emptyMessage: String {
        scope == .archived
            ? "Archived matters will stay encrypted here until you restore them to Active."
            : "See protected handoffs, recent documents, and restores in one local workspace."
    }
}

private struct NewMatterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @FocusState private var isLabelFocused: Bool

    let onCreate: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.lg) {
            VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                Text("New matter")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("Use a client or matter name you will recognize. The app will start an Anonymize session with consistent protected placeholders.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Client or matter name", text: $label)
                .textFieldStyle(.roundedBorder)
                .focused($isLabelFocused)
                .onSubmit(create)

            Label(
                "The matter appears in this workspace after your first Copy for AI.",
                systemImage: "lock.laptopcomputer"
            )
            .font(.caption)
            .foregroundStyle(CounselTheme.textSecondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Anonymizing") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(cleanedLabel == nil)
            }
        }
        .padding(CounselTheme.Space.xl)
        .frame(width: 460)
        .background(CounselTheme.appSurface)
        .onAppear { isLabelFocused = true }
    }

    private var cleanedLabel: String? {
        MatterWorkspacePresentation.cleanedLabel(label)
    }

    private func create() {
        guard let cleanedLabel else { return }
        onCreate(cleanedLabel)
        dismiss()
    }
}

private struct RenameMatterSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var errorMessage: String?
    @FocusState private var isLabelFocused: Bool

    let currentLabel: String
    let onRename: (String) throws -> Void

    init(
        currentLabel: String,
        onRename: @escaping (String) throws -> Void
    ) {
        self.currentLabel = currentLabel
        self.onRename = onRename
        _label = State(initialValue: currentLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.lg) {
            VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                Text("Rename matter")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("Prior handoffs will stay together under the new name. Protected identities remain encrypted.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Client or matter name", text: $label)
                .textFieldStyle(.roundedBorder)
                .focused($isLabelFocused)
                .onSubmit(rename)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(cleanedLabel == nil || cleanedLabel == currentLabel)
            }
        }
        .padding(CounselTheme.Space.xl)
        .frame(width: 460)
        .background(CounselTheme.appSurface)
        .onAppear { isLabelFocused = true }
        .alert(
            "Could not rename matter",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Please try again.")
        }
    }

    private var cleanedLabel: String? {
        MatterWorkspacePresentation.cleanedLabel(label)
    }

    private func rename() {
        guard let cleanedLabel, cleanedLabel != currentLabel else { return }
        do {
            try onRename(cleanedLabel)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum MatterDateFormatter {
    static func full(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    static func relative(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(.relative(presentation: .named))
    }
}

private struct PendingMatterTransition {
    let label: String
    let destination: MatterWorkspaceDestination
}

private struct PendingMatterArchive {
    let summary: MatterSummary
    let discardsActiveWork: Bool
}
