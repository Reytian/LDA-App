//
//  FillShellSheets.swift
//  LDAUI
//
//  Sheet bodies and confirm methods for FillShell. Split from FillShell.swift
//  to respect the 800-line file cap.
//
//  Contains:
//  - importProfileSheet body + confirmImportProfile()
//  - exportProfilePassphraseSheet body + confirmExportFromLibrary()
//  - saveProfilePassphraseSheet body + confirmSaveProfile()
//  - loadProfilePassphraseSheet body + confirmLoadProfile()
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import LDACore

// MARK: - FillShell sheets

extension FillShell {

    // MARK: - Library Import sheet

    var importProfileSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Import portfolio")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text("If this file was saved with a passphrase, enter it. Leave it blank if it uses the Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            L10n.secureField("Passphrase (optional)", text: $passphraseInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) {
                    isImportingProfile = false
                    pendingImportURL = nil
                    passphraseInput = ""
                }
                .keyboardShortcut(.cancelAction)

                L10n.button("Import") {
                    confirmImportProfile()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }

    func confirmImportProfile() {
        isImportingProfile = false
        guard let url = pendingImportURL else {
            pendingImportURL = nil
            passphraseInput = ""
            return
        }
        let isPassphrase = !passphraseInput.isEmpty
        let capturedPassphrase = passphraseInput
        pendingImportURL = nil
        passphraseInput = ""
        if isPassphrase {
            // Passphrase-protected: decrypt with the supplied passphrase directly.
            Task {
                await model.importPortfolio(from: url, protection: .passphrase(capturedPassphrase))
            }
        } else {
            // Keychain-protected: use the fallback chain so files saved by any prior
            // edge (pre-portal UI stored account = filename WITH extension; portal UI
            // uses WITHOUT extension; CLI and MCP had their own prefixes) can all be
            // imported without requiring the user to know which account was used.
            Task {
                await model.importPortfolioWithKeychainFallback(from: url)
            }
        }
    }

    // MARK: - Library Export sheet

    var exportProfilePassphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Protect the export")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text("Enter an optional passphrase to encrypt the exported file. Leave it blank to protect it with the system Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = pendingExportURL, Self.isUnderICloud(url) {
                L10n.label(
                    "This folder syncs to iCloud. The encrypted file will be uploaded with it.",
                    systemImage: "icloud.and.arrow.up"
                )
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            }

            L10n.secureField("Passphrase (optional)", text: $passphraseInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) {
                    isExportingWithPassphrase = false
                    exportingSummary = nil
                    pendingExportURL = nil
                    passphraseInput = ""
                }
                .keyboardShortcut(.cancelAction)

                L10n.button("Export") {
                    confirmExportFromLibrary()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }

    func confirmExportFromLibrary() {
        isExportingWithPassphrase = false
        guard let summary = exportingSummary, let url = pendingExportURL else {
            exportingSummary = nil
            pendingExportURL = nil
            passphraseInput = ""
            return
        }
        let protection: MappingProtection = passphraseInput.isEmpty
            ? .keychain(account: ProfileStore.standardAccount(for: url))
            : .passphrase(passphraseInput)
        let capturedID = summary.id
        exportingSummary = nil
        pendingExportURL = nil
        passphraseInput = ""
        Task {
            await model.exportPortfolio(id: capturedID, to: url, protection: protection)
        }
    }

    // MARK: - Save Profile sheet

    var saveProfilePassphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Protect the profile")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text("Enter an optional passphrase to encrypt the profile. Leave it blank to protect it with the system Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = pendingSaveURL, Self.isUnderICloud(url) {
                L10n.label(
                    "This folder syncs to iCloud. The encrypted profile will be uploaded with it.",
                    systemImage: "icloud.and.arrow.up"
                )
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
            }

            L10n.secureField("Passphrase (optional)", text: $passphraseInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) {
                    isSavingWithPassphrase = false
                    pendingSaveURL = nil
                    passphraseInput = ""
                }
                .keyboardShortcut(.cancelAction)

                L10n.button("Save") {
                    confirmSaveProfile()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }

    func confirmSaveProfile() {
        isSavingWithPassphrase = false
        guard let url = pendingSaveURL, let profile = model.profile else {
            pendingSaveURL = nil
            passphraseInput = ""
            return
        }
        let protection: MappingProtection = passphraseInput.isEmpty
            ? .keychain(account: ProfileStore.standardAccount(for: url))
            : .passphrase(passphraseInput)
        pendingSaveURL = nil
        passphraseInput = ""
        do {
            try ProfileStore.save(profile, to: url, protection: protection)
        } catch {
            showAlert(
                title: L10n.string("Save failed"),
                text: error.localizedDescription,
                warning: true
            )
        }
    }

    // MARK: - Load Profile sheet

    var loadProfilePassphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            L10n.text("Profile passphrase")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            L10n.text("If this profile was saved with a passphrase, enter it. Leave it blank if it uses the Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            L10n.secureField("Passphrase (optional)", text: $passphraseInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) {
                    isLoadingWithPassphrase = false
                    pendingLoadURL = nil
                    passphraseInput = ""
                }
                .keyboardShortcut(.cancelAction)

                L10n.button("Load") {
                    confirmLoadProfile()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }

    func confirmLoadProfile() {
        isLoadingWithPassphrase = false
        guard let url = pendingLoadURL else {
            pendingLoadURL = nil
            passphraseInput = ""
            return
        }
        let isPassphrase = !passphraseInput.isEmpty
        let capturedPassphrase = passphraseInput
        pendingLoadURL = nil
        passphraseInput = ""
        do {
            let profile: ClientPortfolio
            if isPassphrase {
                profile = try ProfileStore.load(from: url, protection: .passphrase(capturedPassphrase))
            } else {
                profile = try ProfileStore.loadWithAccountFallback(from: url)
            }
            // Clear currentPortfolioID before loading so Save will create a new
            // library entry rather than overwriting whatever portfolio was previously
            // open. An externally loaded file is not yet in the library; treating it
            // as an update to the open portfolio would silently corrupt that entry.
            model.currentPortfolioID = nil
            model.loadProfile(profile)
        } catch {
            showAlert(
                title: L10n.string("Load failed"),
                text: error.localizedDescription,
                warning: true
            )
        }
    }
}
