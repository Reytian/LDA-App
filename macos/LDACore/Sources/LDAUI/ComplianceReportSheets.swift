//
//  ComplianceReportSheets.swift
//  LDAUI
//
//  The two passphrase sheets of the compliance report flow. They follow the
//  workspace sheets' idiom: a headline, a plain explanation, the fields, and a
//  prominent confirming button.
//
//  The export sheet adds one thing the workspace sheet has no need for: a
//  shape choice. A report is written to be handed over, and some recipients
//  (a regulator, a client) have no copy of LDA, so the readable pair has to
//  remain reachable. It is offered as a radio choice that starts on the
//  encrypted shape, and the readable option states in plain words what it
//  puts on disk.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI

// MARK: - Export

struct ComplianceReportExportSheet: View {

    @ObservedObject var flow: ComplianceReportFlowModel
    let onConfirm: () -> Void

    private var issue: WorkspacePresentation.PassphraseIssue? {
        ComplianceReportPresentation.passphraseIssue(
            passphrase: flow.passphrase,
            confirmation: flow.confirmation
        )
    }

    private var canConfirm: Bool {
        ComplianceReportPresentation.canConfirmExport(
            shape: flow.shape,
            passphrase: flow.passphrase,
            confirmation: flow.confirmation
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text(ComplianceReportPresentation.exportHeadline)
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text(ComplianceReportPresentation.exportExplanation)
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            shapePicker

            if flow.shape == .encrypted {
                passphraseFields
            } else {
                Label {
                    L10n.text(ComplianceReportPresentation.readableWarning)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) { flow.cancel() }
                    .keyboardShortcut(.cancelAction)

                L10n.button("Export Report") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(minWidth: 440)
        .background(CounselTheme.raised)
    }

    private var shapePicker: some View {
        // The label is empty because .labelsHidden() removes it anyway; the
        // label-closure form is used so no literal sits in a localizing
        // position for the scanner to have to forgive.
        Picker(selection: $flow.shape) {
            L10n.text(ComplianceReportPresentation.encryptedOptionTitle)
                .tag(ComplianceReportPresentation.Shape.encrypted)
            L10n.text(ComplianceReportPresentation.readableOptionTitle)
                .tag(ComplianceReportPresentation.Shape.readable)
        } label: {
            EmptyView()
        }
        .pickerStyle(.radioGroup)
        .labelsHidden()
    }

    @ViewBuilder
    private var passphraseFields: some View {
        L10n.text(ComplianceReportPresentation.encryptedOptionNote)
            .font(.callout)
            .foregroundStyle(CounselTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

        L10n.secureField("Passphrase", text: $flow.passphrase)
            .textFieldStyle(.roundedBorder)
            .frame(width: 320)

        L10n.secureField("Confirm passphrase", text: $flow.confirmation)
            .textFieldStyle(.roundedBorder)
            .frame(width: 320)

        Label {
            L10n.text(ComplianceReportPresentation.irrecoverabilityNote)
        } icon: {
            Image(systemName: "key.fill")
        }
        .font(.callout)
        .foregroundStyle(CounselTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)

        if let issue, !flow.passphrase.isEmpty {
            Text(verbatim: ComplianceReportPresentation.message(for: issue))
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
        }
    }
}

// MARK: - Open

struct ComplianceReportOpenSheet: View {

    @ObservedObject var flow: ComplianceReportFlowModel
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text(ComplianceReportPresentation.openHeadline)
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text(ComplianceReportPresentation.openExplanation)
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            L10n.secureField("Passphrase", text: $flow.passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            if let message = flow.sheetMessage {
                Text(verbatim: message)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) { flow.cancel() }
                    .keyboardShortcut(.cancelAction)

                L10n.button("Open") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(flow.passphrase.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .background(CounselTheme.raised)
    }
}
