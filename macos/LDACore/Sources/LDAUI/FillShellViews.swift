//
//  FillShellViews.swift
//  LDAUI
//
//  Profile-builder subviews for FillShell. Fill-review views were split to
//  FillReviewViews.swift to respect the 800-line file cap.
//
//  Contains:
//  - ProfileBuilderBody: the left/right split for the profile builder stage.
//  - SourceListPane: the imported source documents sidebar.
//  - ProfileFieldTable: the editable field list with conflict resolve controls
//    and verified/unverified badges.
//  - ProfileFieldRow: one field row with editable value and conflict resolve menu.
//  - ConfidenceBar: small horizontal bar showing extraction confidence.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - ProfileBuilderBody

/// The two-column layout for the profile builder: a source list on the left
/// and the editable field table on the right (or an empty-state prompt when
/// no profile exists yet).
struct ProfileBuilderBody: View {
    @ObservedObject var model: FillModel
    let sourcePaths: [URL]

    var body: some View {
        HStack(spacing: 0) {
            SourceListPane(sourcePaths: sourcePaths)
                .frame(width: 220)
                .background(CounselTheme.appSurface)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(CounselTheme.hairline).frame(width: 1)
                }

            if let profile = model.profile {
                ProfileFieldTable(model: model, profile: profile)
            } else {
                profileEmptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var profileEmptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent.opacity(0.8))

            VStack(spacing: 6) {
                Text("No profile yet")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("Add source documents and click Extract, or load a saved .ldaprofile.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 400)
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - SourceListPane

/// The narrow left pane showing the source document names added by the user.
struct SourceListPane: View {
    let sourcePaths: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sources")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CounselTheme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(CounselTheme.hairline).frame(height: 1)
                }

            if sourcePaths.isEmpty {
                Text("No sources added")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .padding(12)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sourcePaths, id: \.absoluteString) { url in
                            Label(url.lastPathComponent, systemImage: "doc.text")
                                .font(.callout)
                                .foregroundStyle(CounselTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }
}

// MARK: - ProfileFieldTable

/// The main body of the profile builder: a list of profile fields, each with
/// an editable value, a source label, a confidence bar, and a verified badge.
/// Conflict rows add a Menu to pick the winning candidate.
struct ProfileFieldTable: View {
    @ObservedObject var model: FillModel
    let profile: ClientPortfolio

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                // Header row
                fieldHeaderRow

                ForEach(profile.fields) { field in
                    ProfileFieldRow(
                        model: model,
                        field: field,
                        isConflicted: profile.conflictedKeys.contains(field.key),
                        conflictCandidates: profile.fields.filter { $0.key == field.key }
                    )
                    Rectangle()
                        .fill(CounselTheme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CounselTheme.paper)
    }

    private var fieldHeaderRow: some View {
        HStack(spacing: 0) {
            columnHeader("Field", width: 180)
            columnHeader("Value", minWidth: 200)
            columnHeader("Source", width: 160)
            columnHeader("Confidence", width: 100)
            columnHeader("", width: 24) // verified badge column
        }
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    private func columnHeader(_ text: String, width: CGFloat? = nil, minWidth: CGFloat? = nil) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(CounselTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(
                minWidth: minWidth ?? width,
                maxWidth: minWidth != nil ? .infinity : width,
                alignment: .leading
            )
    }
}

// MARK: - ProfileFieldRow

/// One row in the profile field table. The value cell is an editable
/// TextField bound back through model.updateField. The source snippet shows
/// on hover in a tooltip. Conflict rows show a Menu to pick the winning field.
struct ProfileFieldRow: View {
    @ObservedObject var model: FillModel
    let field: ProfileField
    let isConflicted: Bool
    let conflictCandidates: [ProfileField]

    @State private var editedValue: String

    init(
        model: FillModel,
        field: ProfileField,
        isConflicted: Bool,
        conflictCandidates: [ProfileField]
    ) {
        self.model = model
        self.field = field
        self.isConflicted = isConflicted
        self.conflictCandidates = conflictCandidates
        self._editedValue = State(initialValue: field.value)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Key / display name
            HStack(spacing: 6) {
                if isConflicted {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(CounselTheme.danger)
                }
                Text(field.key.displayName)
                    .font(.callout)
                    .foregroundStyle(isConflicted ? CounselTheme.danger : CounselTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .frame(width: 180, alignment: .leading)

            // Value: editable text field
            Group {
                if isConflicted {
                    // Conflict: show value + a resolve menu
                    conflictValueCell
                } else {
                    TextField("", text: $editedValue)
                        .textFieldStyle(.plain)
                        .font(.callout.monospaced())
                        .foregroundStyle(
                            field.userEdited
                                ? CounselTheme.inkAccent
                                : CounselTheme.textPrimary
                        )
                        .onSubmit {
                            if editedValue != field.value {
                                model.updateField(id: field.id, value: editedValue)
                            }
                        }
                        .onChange(of: field.value) { _, newVal in
                            editedValue = newVal
                        }
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)

            // Source document name
            Text(field.sourceDocument)
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .frame(width: 160, alignment: .leading)

            // Confidence bar
            ConfidenceBar(confidence: field.confidence)
                .padding(.horizontal, 12)
                .frame(width: 100, alignment: .leading)

            // Verified badge, with source snippet as tooltip
            verifiedBadge
                .frame(width: 24, alignment: .center)
                .padding(.trailing, 8)
        }
        .padding(.vertical, 6)
        .background(isConflicted ? CounselTheme.danger.opacity(0.05) : Color.clear)
    }

    private var conflictValueCell: some View {
        HStack(spacing: 8) {
            Text(field.value)
                .font(.callout.monospaced())
                .foregroundStyle(CounselTheme.danger)
                .lineLimit(1)
                .truncationMode(.middle)

            Menu {
                ForEach(conflictCandidates) { candidate in
                    Button {
                        model.resolveConflict(key: field.key, keepFieldID: candidate.id)
                    } label: {
                        HStack {
                            Text(candidate.value)
                            if candidate.id == field.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Resolve", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.danger)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose which value to keep for \(field.key.displayName)")
        }
    }

    @ViewBuilder
    private var verifiedBadge: some View {
        if field.snippetVerified {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(CounselTheme.inkAccent)
                .help(field.sourceSnippet.isEmpty
                    ? "Verified: the value was found verbatim in the source document"
                    : "Verified. Source: \(field.sourceSnippet)")
                .accessibilityLabel("Verified")
        } else {
            Image(systemName: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary.opacity(0.5))
                .help(field.sourceSnippet.isEmpty
                    ? "Unverified: the value was not confirmed verbatim in the source"
                    : "Unverified. Extracted from: \(field.sourceSnippet)")
                .accessibilityLabel("Unverified")
        }
    }
}

// MARK: - ConfidenceBar

/// A small horizontal bar showing extraction confidence.
struct ConfidenceBar: View {
    let confidence: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(CounselTheme.hairline)
                RoundedRectangle(cornerRadius: 2)
                    .fill(confidenceColor)
                    .frame(width: geo.size.width * max(0, min(1, confidence)))
            }
        }
        .frame(height: 4)
        .accessibilityLabel("Confidence \(Int((confidence * 100).rounded()))%")
    }

    private var confidenceColor: Color {
        if confidence >= 0.75 { return CounselTheme.inkAccent }
        if confidence >= 0.4 { return CounselTheme.textSecondary }
        return CounselTheme.danger
    }
}

