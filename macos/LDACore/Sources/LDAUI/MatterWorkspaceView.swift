//
//  MatterWorkspaceView.swift
//  LDAUI
//
//  A local workspace assembled from existing client mappings, encrypted
//  value-free session records, and encrypted organization metadata.
//
//  Interface copy uses localization keys. Matter labels, document names, and
//  stored error details remain verbatim.
//

import Foundation
import SwiftUI
import LDACore

enum MatterWorkspaceLocalization {
    static func loadFailureTitleKey(
        clientListFailed: Bool,
        historyFailed: Bool,
        metadataFailed: Bool
    ) -> String {
        let failureCount = [clientListFailed, historyFailed, metadataFailed]
            .filter { $0 }
            .count
        if failureCount > 1 {
            return "Some workspace data is locked"
        }
        if clientListFailed {
            return "Saved client list is locked"
        }
        if historyFailed {
            return "Recent activity is locked"
        }
        return "Matter organization is locked"
    }

    static func emptySidebarTitleKey(
        isSearching: Bool,
        scope: MatterWorkspaceScope
    ) -> String {
        if isSearching { return "No matching matters" }
        return scope == .archived ? "No archived matters" : "No matters yet"
    }

    static func emptySidebarMessageKey(scope: MatterWorkspaceScope) -> String {
        scope == .archived
            ? "Archived matters stay encrypted here until you restore or delete them."
            : "Start one to keep its protected handoffs together."
    }

    static func emptyDetailTitleKey(scope: MatterWorkspaceScope) -> String {
        scope == .archived ? "No archived matters" : "Keep each matter in context"
    }

    static func emptyDetailMessageKey(scope: MatterWorkspaceScope) -> String {
        scope == .archived
            ? "Archived matters will stay encrypted here until you restore them to Active."
            : "See protected handoffs, recent documents, and restores in one local workspace."
    }

    static func archiveActionKey(isArchived: Bool) -> String {
        isArchived ? "Restore to Active" : "Archive Matter"
    }

    static func archiveConfirmationActionKey(discardsActiveWork: Bool) -> String {
        discardsActiveWork ? "Close Active Work and Archive" : "Archive Matter"
    }

    static func handoffLabelKey(count: Int) -> String {
        count == 1 ? "Handoff" : "Handoffs"
    }

    static func documentLabelKey(count: Int) -> String {
        count == 1 ? "Document" : "Documents"
    }

    static func identityLabelKey(count: Int) -> String {
        count == 1 ? "Known Identity" : "Known Identities"
    }

    static func restoreLabelKey(count: Int) -> String {
        count == 1 ? "Restore" : "Restores"
    }

    static func localWorkspaceSummary(
        count: Int,
        language: AppLanguage? = nil
    ) -> String {
        guard count > 0 else {
            return L10n.string("Local workspaces", language: language)
        }
        return format(
            count == 1 ? "%lld local workspace" : "%lld local workspaces",
            language: language,
            arguments: [Int64(count)]
        )
    }

    static func activityLine(
        relativeActivity: String?,
        language: AppLanguage? = nil
    ) -> String {
        guard let relativeActivity else {
            return L10n.string("Ready for first handoff", language: language)
        }
        return format(
            "Updated %@",
            language: language,
            arguments: [relativeActivity]
        )
    }

    static func documentLine(
        names: [String],
        language: AppLanguage? = nil
    ) -> String {
        guard !names.isEmpty else {
            return L10n.string("No document names recorded", language: language)
        }
        return names.joined(separator: ", ")
    }

    static func restoreLine(
        hasRestoreEvents: Bool,
        restoredCount: Int,
        flaggedCount: Int,
        language: AppLanguage? = nil
    ) -> String {
        guard hasRestoreEvents else {
            return L10n.string("Awaiting restored result", language: language)
        }
        if flaggedCount > 0 {
            return format(
                restoredCount == 1
                    ? "%lld value restored, %lld flagged for review"
                    : "%lld values restored, %lld flagged for review",
                language: language,
                arguments: [Int64(restoredCount), Int64(flaggedCount)]
            )
        }
        return format(
            restoredCount == 1 ? "%lld value restored" : "%lld values restored",
            language: language,
            arguments: [Int64(restoredCount)]
        )
    }

    private static func format(
        _ key: String,
        language: AppLanguage?,
        arguments: [CVarArg]
    ) -> String {
        let selectedLanguage = language ?? AppLanguage.selected()
        return String(
            format: L10n.string(key, language: language),
            locale: selectedLanguage.locale,
            arguments: arguments
        )
    }
}

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
    @State private var pendingDelete: MatterSummary?
    @State private var workspaceError: String?
    @State private var windowChromeTopInset: CGFloat = 0

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
        .background(WindowContentTopInsetReader(topInset: $windowChromeTopInset))
        .toolbar {
            if isActive {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isNewMatterPresented = true
                    } label: {
                        L10n.label("New Matter", systemImage: "plus")
                    }
                    .l10nHelp("Start a protected workflow for a new client or matter")
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
        .l10nConfirmationDialog(
            "Close current work?",
            isPresented: Binding(
                get: { pendingTransition != nil },
                set: { if !$0 { pendingTransition = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingTransition {
                L10n.button("Close Active Work and Switch", role: .destructive) {
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
            L10n.button("Cancel", role: .cancel) {
                pendingTransition = nil
            }
        } message: {
            L10n.text("Switching matters closes the documents and any unfinished restore context in this window. Saved files are not affected.")
        }
        .l10nConfirmationDialog(
            "Archive %@?",
            arguments: [pendingArchive?.summary.label ?? L10n.string("matter")],
            isPresented: Binding(
                get: { pendingArchive != nil },
                set: { if !$0 { pendingArchive = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingArchive {
                L10n.button(
                    MatterWorkspaceLocalization.archiveConfirmationActionKey(
                        discardsActiveWork: pendingArchive.discardsActiveWork
                    ),
                    role: pendingArchive.discardsActiveWork ? .destructive : nil
                ) {
                    archive(pendingArchive)
                }
            }
            L10n.button("Cancel", role: .cancel) {
                pendingArchive = nil
            }
        } message: {
            if pendingArchive?.discardsActiveWork == true {
                L10n.text("Archiving closes the documents and unfinished restore context in this window. Saved files are not affected, and the matter can be restored from Archived.")
            } else {
                L10n.text("The matter will move out of Active. Its encrypted identities and history are kept and can be restored later.")
            }
        }
        .l10nConfirmationDialog(
            "Delete %@ permanently?",
            arguments: [pendingDelete?.label ?? L10n.string("matter")],
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDelete {
                L10n.button("Delete Matter", role: .destructive) {
                    delete(pendingDelete)
                }
            }
            L10n.button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            L10n.text("This removes the matter's encrypted identities, local history, and matter-only rules from LDA. Saved or exported workspace, redacted, report, and restored files are not affected.")
        }
        .l10nAlert(
            "Could not update matter",
            isPresented: Binding(
                get: { workspaceError != nil },
                set: { if !$0 { workspaceError = nil } }
            )
        ) {
            L10n.button("OK", role: .cancel) {}
        } message: {
            if let workspaceError {
                Text(workspaceError)
            } else {
                L10n.text("Please try again.")
            }
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
            WindowChromeTopSpacer(height: windowChromeTopInset, background: Color.clear)

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                    L10n.text("Matters")
                        .font(.system(.title3, design: .serif).weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    Text(
                        MatterWorkspaceLocalization.localWorkspaceSummary(
                            count: summaries.count
                        )
                    )
                        .font(CounselTheme.Typography.supporting)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
                Spacer()
                Button {
                    isNewMatterPresented = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .l10nHelp("New Matter")
            }
            .padding(.horizontal, CounselTheme.Space.lg)
            .padding(.vertical, CounselTheme.Space.md)

            L10n.picker("Matter status", selection: $scope) {
                L10n.text("Active %lld", activeCount).tag(MatterWorkspaceScope.active)
                L10n.text("Archived %lld", archivedCount).tag(MatterWorkspaceScope.archived)
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
                    L10n.text(emptySidebarTitleKey)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    if searchText.isEmpty {
                        L10n.text(emptySidebarMessageKey)
                            .font(CounselTheme.Typography.supporting)
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
                                L10n.label("Rename Matter", systemImage: "pencil")
                            }
                            .disabled(loadFailed)

                            Divider()

                            Button {
                                requestArchiveToggle(summary)
                            } label: {
                                L10n.label(
                                    MatterWorkspaceLocalization.archiveActionKey(
                                        isArchived: summary.isArchived
                                    ),
                                    systemImage: summary.isArchived
                                        ? "arrow.uturn.backward.circle"
                                        : "archivebox"
                                )
                            }
                            .disabled(metadataLoadFailed)

                            if MatterWorkspacePresentation.canDelete(summary) {
                                Divider()
                                Button(role: .destructive) {
                                    pendingDelete = summary
                                } label: {
                                    L10n.label("Delete Matter", systemImage: "trash")
                                }
                                .disabled(loadFailed)
                            }
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
                        L10n.text(loadFailureTitleKey)
                            .font(.caption.weight(.semibold))
                        L10n.button("Try Again") { reload() }
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
                onArchiveToggle: { requestArchiveToggle(summary) },
                onDelete: { pendingDelete = summary }
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

    private var loadFailureTitleKey: String {
        MatterWorkspaceLocalization.loadFailureTitleKey(
            clientListFailed: clientListLoadFailed,
            historyFailed: historyLoadFailed,
            metadataFailed: metadataLoadFailed
        )
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

    private var emptySidebarTitleKey: String {
        MatterWorkspaceLocalization.emptySidebarTitleKey(
            isSearching: !searchText.isEmpty,
            scope: scope
        )
    }

    private var emptySidebarMessageKey: String {
        MatterWorkspaceLocalization.emptySidebarMessageKey(scope: scope)
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

    private func delete(_ summary: MatterSummary) {
        guard MatterWorkspacePresentation.canDelete(summary) else {
            pendingDelete = nil
            return
        }
        do {
            try session.deleteMatter(summary.label)
            selectedMatterID = nil
            reload()
        } catch {
            workspaceError = error.localizedDescription
        }
        pendingDelete = nil
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
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, CounselTheme.Space.xs)
    }

    private var activityLine: String {
        MatterWorkspaceLocalization.activityLine(
            relativeActivity: summary.lastActivityISO8601.map {
                MatterDateFormatter.relative($0)
            }
        )
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
    let onDelete: () -> Void

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
                        L10n.text("MATTER WORKSPACE")
                            .font(.caption.weight(.semibold))
                            .tracking(0.8)
                            .foregroundStyle(CounselTheme.inkAccent)
                        if summary.isArchived {
                            L10n.label("Archived", systemImage: "archivebox.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(CounselTheme.textSecondary)
                        }
                    }
                    Text(summary.label)
                        .font(.system(size: 30, weight: .semibold, design: .serif))
                        .foregroundStyle(CounselTheme.textPrimary)
                    if let stamp = summary.lastActivityISO8601 {
                        L10n.text("Last activity %@", MatterDateFormatter.full(stamp))
                            .font(.callout)
                            .foregroundStyle(CounselTheme.textSecondary)
                    } else {
                        L10n.text("No protected handoffs recorded yet.")
                            .font(.callout)
                            .foregroundStyle(CounselTheme.textSecondary)
                    }
                }
                Spacer()
                Menu {
                    Button(action: onRename) {
                        L10n.label("Rename Matter", systemImage: "pencil")
                    }
                    Divider()
                    Button(action: onArchiveToggle) {
                        L10n.label(
                            MatterWorkspaceLocalization.archiveActionKey(
                                isArchived: summary.isArchived
                            ),
                            systemImage: summary.isArchived
                                ? "arrow.uturn.backward.circle"
                                : "archivebox"
                            )
                    }
                    if MatterWorkspacePresentation.canDelete(summary) {
                        Divider()
                        Button(role: .destructive, action: onDelete) {
                            L10n.label("Delete Matter", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .l10nHelp("Matter actions")
            }

            if summary.isArchived {
                HStack(spacing: CounselTheme.Space.md) {
                    Button(action: onArchiveToggle) {
                        L10n.label("Restore to Active", systemImage: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    L10n.text("Restore this matter before starting another protected handoff.")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
            } else {
                HStack(spacing: CounselTheme.Space.md) {
                    Button(action: onAnonymize) {
                        L10n.label("Anonymize Documents", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)

                    Button(action: onRestore) {
                        L10n.label("Restore AI Answer", systemImage: "arrow.uturn.backward.circle")
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
                label: MatterWorkspaceLocalization.handoffLabelKey(
                    count: summary.sessionCount
                ),
                systemImage: "arrow.right.doc.on.clipboard"
            )
            MatterMetricCard(
                value: summary.documentCount,
                label: MatterWorkspaceLocalization.documentLabelKey(
                    count: summary.documentCount
                ),
                systemImage: "doc.on.doc"
            )
            MatterMetricCard(
                value: summary.protectedValueCount,
                label: MatterWorkspaceLocalization.identityLabelKey(
                    count: summary.protectedValueCount
                ),
                systemImage: "person.badge.shield.checkmark"
            )
            MatterMetricCard(
                value: summary.restoreCount,
                label: MatterWorkspaceLocalization.restoreLabelKey(
                    count: summary.restoreCount
                ),
                systemImage: "arrow.uturn.backward"
            )
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: CounselTheme.Space.md) {
            L10n.text("Recent activity")
                .font(.system(.title3, design: .serif).weight(.semibold))
                .foregroundStyle(CounselTheme.textPrimary)

            if !historyAvailable {
                L10n.label(
                    "Some recent activity could not be unlocked. Readable handoffs remain below.",
                    systemImage: "exclamationmark.lock"
                )
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
            }

            if records.isEmpty, historyAvailable {
                VStack(alignment: .leading, spacing: CounselTheme.Space.xs) {
                    L10n.text("Start with an anonymized handoff")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.textPrimary)
                    L10n.text("After Export for AI, this page will show the documents and counts for the handoff.")
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
            L10n.text("Matter names, archive status, counts, and document names are stored in encrypted local records. Protected values and document contents are never stored here.")
        } icon: {
            Image(systemName: "lock.laptopcomputer")
        }
        .font(CounselTheme.Typography.supporting)
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
            L10n.text("%lld", value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(CounselTheme.textPrimary)
            L10n.text(label)
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
                    L10n.text("%lld protected", record.protectedValueCount)
                        .font(.caption)
                        .foregroundStyle(CounselTheme.textSecondary)
                }
                Text(documentLine)
                    .font(CounselTheme.Typography.supporting)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .lineLimit(2)
                Text(restoreLine)
                    .font(CounselTheme.Typography.supporting)
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
        MatterWorkspaceLocalization.documentLine(
            names: record.documents.map(\.name)
        )
    }

    private var recordFlagCount: Int {
        record.restoreEvents.reduce(0) {
            $0 + $1.orphanCount + $1.suspectCount + $1.ambiguousCount
        }
    }

    private var restoreLine: String {
        let restored = record.restoreEvents.reduce(0) { $0 + $1.restoredCount }
        return MatterWorkspaceLocalization.restoreLine(
            hasRestoreEvents: !record.restoreEvents.isEmpty,
            restoredCount: restored,
            flaggedCount: recordFlagCount
        )
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
                L10n.text(
                    MatterWorkspaceLocalization.emptyDetailTitleKey(scope: scope)
                )
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text(emptyMessageKey)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if scope == .active {
                Button(action: onNewMatter) {
                    L10n.label("Start a New Matter", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CounselTheme.paper)
    }

    private var emptyMessageKey: String {
        MatterWorkspaceLocalization.emptyDetailMessageKey(scope: scope)
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
                L10n.text("New matter")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text("Use a client or matter name you will recognize. The app will start an Anonymize session with consistent protected placeholders.")
                    .font(CounselTheme.Typography.readingBody)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            L10n.textField("Client or matter name", text: $label)
                .textFieldStyle(.roundedBorder)
                .focused($isLabelFocused)
                .onSubmit(create)

            L10n.label(
                "The matter appears in this workspace after your first Export for AI.",
                systemImage: "lock.laptopcomputer"
            )
            .font(CounselTheme.Typography.supporting)
            .foregroundStyle(CounselTheme.textSecondary)

            HStack {
                Spacer()
                L10n.button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                L10n.button("Start Anonymizing") { create() }
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
                L10n.text("Rename matter")
                    .font(.system(.title2, design: .serif).weight(.semibold))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text("Prior handoffs will stay together under the new name. Protected identities remain encrypted.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            L10n.textField("Client or matter name", text: $label)
                .textFieldStyle(.roundedBorder)
                .focused($isLabelFocused)
                .onSubmit(rename)

            HStack {
                Spacer()
                L10n.button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                L10n.button("Rename") { rename() }
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
        .l10nAlert(
            "Could not rename matter",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            L10n.button("OK", role: .cancel) {}
        } message: {
            if let errorMessage {
                Text(errorMessage)
            } else {
                L10n.text("Please try again.")
            }
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

enum MatterDateFormatter {
    static func full(
        _ iso: String,
        language: AppLanguage? = nil
    ) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let selectedLanguage = language ?? AppLanguage.selected()
        let formatter = DateFormatter()
        formatter.locale = selectedLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func relative(
        _ iso: String,
        language: AppLanguage? = nil,
        relativeTo referenceDate: Date = Date()
    ) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        let selectedLanguage = language ?? AppLanguage.selected()
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = selectedLanguage.locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: referenceDate)
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
