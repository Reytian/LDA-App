import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Full window content, rather than a dismissible sheet over usable workflows.
public struct LegalConsentView: View {
    @ObservedObject private var acceptance: LegalAcceptanceStore
    @State private var acceptsTerms = false
    @State private var acceptsPrivacy = false
    @State private var saveFailed = false

    public init(acceptance: LegalAcceptanceStore) {
        self.acceptance = acceptance
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(CounselTheme.textSecondary)
                VStack(alignment: .leading, spacing: 4) {
                    L10n.text("Before you begin")
                        .font(.system(.title, design: .serif).weight(.semibold))
                    L10n.text("Please review and accept both documents to continue using LDA.")
                        .font(.callout)
                }
            }

            LegalDocumentsView(documents: acceptance.documents)

            if acceptance.documents != nil {
                Toggle(isOn: $acceptsTerms) {
                    L10n.text("I have read and agree to the Terms of Service.")
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("legal.acceptTerms")
                Toggle(isOn: $acceptsPrivacy) {
                    L10n.text("I have read and accept the Privacy Policy.")
                }
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("legal.acceptPrivacy")
                L10n.text("Acceptance is saved only on this Mac. It does not authorize optional sharing or future data uses.")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if saveFailed {
                L10n.text("Acceptance could not be saved. Please try again.")
                    .foregroundStyle(.red)
            }

            HStack {
                L10n.button("Decline and Quit") { NSApp.terminate(nil) }
                    .accessibilityIdentifier("legal.decline")
                Spacer()
                L10n.button("Accept and Continue") {
                    do {
                        try acceptance.accept(terms: acceptsTerms, privacy: acceptsPrivacy)
                    } catch {
                        saveFailed = true
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!acceptsTerms || !acceptsPrivacy || acceptance.documents == nil)
                .accessibilityIdentifier("legal.continue")
            }
        }
        .padding(28)
        .frame(minWidth: 640, maxWidth: 900, minHeight: 620, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CounselTheme.appSurface)
    }
}

struct LegalDocumentsView: View {
    let documents: LegalDocuments?
    @State private var selectedDocument: LegalDocument = .terms
    @State private var exportFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            L10n.picker("Legal document", selection: $selectedDocument) {
                ForEach(LegalDocument.allCases) { document in
                    L10n.text(document.title).tag(document)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("legal.documents")

            if let documents {
                L10n.text("These documents are in English. You can save a copy for your records.")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(documents.text(for: selectedDocument)
                            .components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            if paragraph.hasPrefix("# ") {
                                Text(verbatim: String(paragraph.dropFirst(2)))
                                    .font(.title2.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                            } else if paragraph.hasPrefix("## ") {
                                Text(verbatim: String(paragraph.dropFirst(3)))
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                            } else {
                                Text(verbatim: paragraph)
                                    .font(.body)
                                    .lineSpacing(3)
                            }
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                }
                .id(selectedDocument)
                .frame(maxHeight: .infinity)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))

                HStack {
                    L10n.button("Save a Copy...") { saveCopy(documents) }
                        .accessibilityIdentifier("legal.saveCopy")
                    Spacer()
                    Link(destination: URL(string: "mailto:formelocale@protonmail.com")!) {
                        L10n.text("Contact Support")
                    }
                }
                if exportFailed {
                    L10n.text("The document could not be saved. Choose another location and try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                L10n.text("The legal documents could not be loaded. Please reinstall LDA from its official distribution.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func saveCopy(_ documents: LegalDocuments) {
        exportFailed = false
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "LDA-\(selectedDocument.rawValue)-\(documents.version).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try documents.text(for: selectedDocument).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            exportFailed = true
        }
    }
}

struct LegalSettingsView: View {
    @ObservedObject var acceptance: LegalAcceptanceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LegalDocumentsView(documents: acceptance.documents)
            if let receipt = acceptance.records.last {
                HStack {
                    L10n.text("Accepted on this Mac:")
                    Text(receipt.acceptedAt, style: .date)
                }
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
            }
        }
        .padding(24)
    }
}

public struct LegalCompanionNotice: View {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        L10n.text("Review the Terms of Service and Privacy Policy to begin.")
        L10n.button("Open LDA") {
            openWindow(id: LDAWindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
