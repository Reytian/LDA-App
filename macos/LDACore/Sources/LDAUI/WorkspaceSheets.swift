//
//  WorkspaceSheets.swift
//  LDAUI
//
//  The two passphrase sheets of the workspace flow. They follow the export
//  sheet's idiom in AppShell: a headline, a plain explanation, the fields, and
//  a prominent confirming button.
//
//  The save sheet differs from the export sheet in one deliberate way: the
//  passphrase is REQUIRED and confirmed. The export sheet allows an empty
//  passphrase because the Keychain can protect a sidecar that never leaves the
//  Mac. A workspace is built to leave, so there is no Keychain fallback to
//  offer and a typo in a passphrase nobody can recover is worth one more field.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

// MARK: - Save

struct WorkspaceSaveSheet: View {

    @ObservedObject var flow: WorkspaceFlowModel
    let onConfirm: () -> Void

    private var issue: WorkspacePresentation.PassphraseIssue? {
        WorkspacePresentation.passphraseIssue(
            passphrase: flow.passphrase,
            confirmation: flow.confirmation
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Protect this workspace")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text("The file holds this matter's documents, your review decisions, and the values needed to restore them. Choose a passphrase for it.")
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
                Text(LocalizedStringKey(WorkspacePresentation.irrecoverabilityNote))
            } icon: {
                Image(systemName: "key.fill")
            }
            .font(.callout)
            .foregroundStyle(CounselTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let issue, !flow.passphrase.isEmpty {
                Text(verbatim: WorkspacePresentation.message(for: issue))
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
            }

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) { flow.cancel() }
                    .keyboardShortcut(.cancelAction)

                L10n.button("Save Workspace") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(issue != nil)
            }
        }
        .padding(24)
        .frame(minWidth: 400)
        .background(CounselTheme.raised)
    }
}

// MARK: - Open

struct WorkspaceOpenSheet: View {

    @ObservedObject var flow: WorkspaceFlowModel
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Open workspace")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text("Enter the passphrase this workspace file was saved with. Its contents are decrypted locally after you enter the passphrase.")
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
