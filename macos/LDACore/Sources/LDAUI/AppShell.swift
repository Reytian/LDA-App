//
//  AppShell.swift
//  LDAUI
//
//  The top-level review window: a NavigationSplitView with the entity sidebar on
//  the leading side and the paper document pane as the detail. The unified
//  toolbar carries the Open control (.fileImporter for txt/docx/pdf), the
//  prominent ink-accent Export control (a directory picker plus an optional
//  passphrase sheet), and the "AI entities" toggle bound to the model. The
//  current status is surfaced unobtrusively as a subtle banner above the pane.
//
//  Counsel direction: the detail is solid paper; the sidebar uses the default
//  sidebar material. Hairlines over shadows. A single ink-blue accent is
//  reserved for the primary Export action and selection.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

/// The Counsel review window shell. Hosts the sidebar and the document pane in a
/// NavigationSplitView and owns the toolbar that drives import and export.
public struct AppShell: View {
    @ObservedObject private var model: ReviewModel

    /// True while the passphrase sheet is presented, after a directory is chosen.
    @State private var isPromptingPassphrase = false

    /// The directory chosen for export, held while the passphrase is collected.
    @State private var pendingExportDir: URL?

    /// The optional passphrase typed into the sheet. Empty means use the
    /// Keychain instead of a passphrase.
    @State private var passphrase = ""

    /// A one-line outcome message shown after an export completes or fails.
    @State private var exportMessage: String?

    public init(model: ReviewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            EntitySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            VStack(spacing: 0) {
                statusBanner
                DocumentPane(model: model)
            }
            .background(CounselTheme.paper)
        }
        .background(CounselTheme.appSurface)
        .navigationTitle("Legal Document Anonymizer")
        .toolbar { toolbarContent }
        .sheet(isPresented: $isPromptingPassphrase) {
            passphraseSheet
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button {
                presentOpenPanel()
            } label: {
                Label("Open", systemImage: "doc.badge.plus")
            }
            .help("Open a .txt, .docx, or .pdf document")
        }

        ToolbarItemGroup(placement: .automatic) {
            Toggle(isOn: $model.useLLM) {
                Label("AI entities", systemImage: "sparkles")
            }
            .toggleStyle(.switch)
            .help("Also run the AI extractor and merge its entities")

            Button {
                beginExport()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccent)
            .disabled(!canExport)
            .help("Tokenize accepted entities and write the redacted document")
        }
    }

    // MARK: - Status banner

    /// A subtle, unobtrusive banner that reflects model.status and the most
    /// recent export outcome. Hidden when idle with nothing to report.
    @ViewBuilder
    private var statusBanner: some View {
        if let text = bannerText {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(text)
                    .font(.callout)
                    .foregroundStyle(bannerIsError
                        ? Color(srgb: 0xB05F5C)
                        : CounselTheme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(CounselTheme.raised)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(CounselTheme.hairline)
                    .frame(height: 1)
            }
        }
    }

    private var bannerText: String? {
        switch model.status {
        case .idle:
            return exportMessage
        case .importing:
            return "Importing document"
        case .detecting:
            return "Detecting entities"
        case .ready:
            return exportMessage ?? "Ready for review"
        case .failed(let detail):
            return detail
        }
    }

    private var bannerIsError: Bool {
        if case .failed = model.status { return true }
        return false
    }

    private var isWorking: Bool {
        switch model.status {
        case .importing, .detecting:
            return true
        default:
            return false
        }
    }

    // MARK: - Passphrase sheet

    private var passphraseSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Protect the mapping")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            Text("Enter an optional passphrase to encrypt the mapping sidecar. "
                + "Leave it blank to protect the mapping with the system Keychain.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Passphrase (optional)", text: $passphrase)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    cancelPassphrase()
                }
                .keyboardShortcut(.cancelAction)

                Button("Export") {
                    confirmExport()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccent)
            }
        }
        .padding(24)
        .frame(minWidth: 380)
        .background(CounselTheme.raised)
    }

    // MARK: - Open flow

    private var canExport: Bool {
        if case .ready = model.status { return true }
        return false
    }

    /// Present a native open panel for the source document. NSOpenPanel is used
    /// instead of SwiftUI .fileImporter because two .fileImporter modifiers on the
    /// same view conflict and silently fail to present.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.openContentTypes
        panel.message = "Choose a .txt, .docx, or .pdf document to anonymize."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportMessage = nil
        let needsScope = url.startAccessingSecurityScopedResource()
        Task {
            await model.open(url)
            if needsScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    // MARK: - Export flow

    private func beginExport() {
        guard canExport else { return }
        exportMessage = nil
        passphrase = ""
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the redacted document and encrypted mapping."
        panel.prompt = "Export Here"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        pendingExportDir = dir
        isPromptingPassphrase = true
    }

    private func cancelPassphrase() {
        isPromptingPassphrase = false
        pendingExportDir = nil
        passphrase = ""
    }

    private func confirmExport() {
        isPromptingPassphrase = false
        guard let dir = pendingExportDir else { return }

        let phrase = passphrase.isEmpty ? nil : passphrase
        let createdAt = ISO8601DateFormatter().string(from: Date())

        let needsScope = dir.startAccessingSecurityScopedResource()
        defer {
            if needsScope { dir.stopAccessingSecurityScopedResource() }
            pendingExportDir = nil
            passphrase = ""
        }

        do {
            let outcome = try model.export(
                to: dir,
                passphrase: phrase,
                createdAtISO8601: createdAt
            )
            exportMessage = "Exported \(outcome.tokenCount) "
                + (outcome.tokenCount == 1 ? "token to " : "tokens to ")
                + outcome.redactedURL.lastPathComponent
        } catch {
            exportMessage = "Export failed. \(error.localizedDescription)"
        }
    }

    // MARK: - Content types

    /// The document types the Open panel accepts: plain text, Word, and PDF.
    private static let openContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .pdf]
        if let docx = UTType(
            "org.openxmlformats.wordprocessingml.document"
        ) {
            types.append(docx)
        }
        return types
    }()
}

// MARK: - Local color helper

private extension Color {
    /// Builds an sRGB color from a 24-bit 0xRRGGBB literal. Mirrors the helper in
    /// CounselTheme so the banner can reuse the PHONE hue for error text.
    init(srgb hex: UInt32) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1.0)
    }
}
