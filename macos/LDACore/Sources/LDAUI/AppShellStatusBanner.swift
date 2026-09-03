//
//  AppShellStatusBanner.swift
//  LDAUI
//
//  The review window's status banner: a subtle strip above the document pane
//  that reflects the active document's status and the most recent export
//  outcome, and that carries the mode's primary action. Kept out of AppShell
//  because that file already carries the shell.
//
//  The primary action (Scan for PII) lives HERE rather than in the toolbar:
//  toolbar items overflow into the >> menu on narrow windows, and the primary
//  action must never disappear.
//
//  The banner reads the active document through the session rather than
//  holding a ReviewModel, so that a tray change under an open banner is
//  picked up. See the seal candidate binding for the case that forced it.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import SwiftUI
import LDACore

/// A subtle, unobtrusive banner that reflects model.status and the most
/// recent export outcome. Hidden when idle with nothing to report.
struct AppShellStatusBanner: View {

    @ObservedObject var session: SessionModel

    /// A one-line outcome message shown after an export completes or fails.
    /// Owned by the shell, which shares it with the workspace and report flows.
    let exportMessage: String?

    /// Whether THIS MAC has any detection model. Passed in from the shell,
    /// which already holds the once-loaded catalog: a second
    /// ModelCatalog.load() here would put a disk read and a JSON parse on the
    /// main thread for every progress publish during a multi gigabyte copy.
    ///
    /// It decides which of two banner sentences and which of two tooltips
    /// render, because the shipped ones promise that a scan finds names.
    let hasDetectionModel: Bool

    /// Whether Touch ID protection actually took effect. Shown next to the
    /// On-device badge when it did not, so the trust claim in the UI matches
    /// what the Keychain is really doing.
    @StateObject private var keychainAdvisory = KeychainAdvisoryStore()

    /// The active document's review model, read fresh on every access.
    private var model: ReviewModel { session.activeModel }

    @ViewBuilder
    var body: some View {
        if case .detecting = model.status {
            bannerChrome {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(CounselTheme.inkAccent)
                    .frame(maxWidth: 300)
                Text(verbatim: detectingLabel)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(CounselTheme.textSecondary)
                Spacer(minLength: 0)
                Button {
                    model.cancelAnonymize()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .font(.callout)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(CounselTheme.danger)
                .help("Stop anonymizing. The document stays loaded; no partial results are shown.")
                .accessibilityIdentifier("stopAnonymize")
            }
        } else if case .ready = model.status {
            reviewSummaryBanner
        } else if let text = bannerText {
            bannerChrome {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(verbatim: text)
                    .font(.callout)
                    .foregroundStyle(bannerIsError
                        ? CounselTheme.danger
                        : CounselTheme.textSecondary)
                Spacer(minLength: 0)
                // The mode's primary action lives IN the banner, next to the
                // sentence that names it: it can never vanish into toolbar
                // overflow on a narrow window.
                if case .imported = model.status {
                    if session.entries.count > 1 {
                        scanAllButton
                    }
                    scanButton(title: "Scan for PII", prominent: true)
                }
            }
        }
    }

    // MARK: - Scan actions

    /// Scan every not-yet-scanned document in tray order (F3). Sequential by
    /// design: one model pass at a time, and the order feeds the
    /// cross-document sweep. The banner's Stop cancels the current document
    /// and leaves the rest of the queue imported.
    private var scanAllButton: some View {
        Button {
            session.requestScanAll()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                Text("Scan All")
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!session.canScanAll)
        .help("Scan every document in the session that has not been scanned yet, one after another")
        .accessibilityIdentifier("scanAllDocuments")
    }

    /// The primary Scan for PII action, rendered with symmetric padding so the
    /// pill is visually even. Available once a document is imported, and again
    /// after a run (so the user can re-run, for example after toggling AI
    /// entities). Not available while a pass is in flight.
    private func scanButton(title: LocalizedStringKey, prominent: Bool) -> some View {
        Group {
            if prominent {
                Button {
                    model.requestAnonymize()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "text.magnifyingglass")
                        Text(title)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
            } else {
                Button {
                    model.requestAnonymize()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text(title)
                    }
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .disabled(!model.canAnonymize)
        .help(L10n.string(hasDetectionModel
              ? "Spot PII in the open document: names, companies, addresses, dates, amounts (Cmd+Shift+S)"
              : "Spot PII in the open document: dates, amounts, emails, phones, ID numbers (Cmd+Shift+S). People's names and company names need a detection model."))
        .accessibilityIdentifier("scanForPII")
    }

    // MARK: - Review summary

    /// The post-anonymize review summary: how many will be redacted, how many the
    /// user rejected (so will remain visible), an AI-unavailable warning, the
    /// learning note, and any export outcome. Gives the lawyer a trust signal
    /// before relying on the output.
    @ViewBuilder
    private var reviewSummaryBanner: some View {
        bannerChrome {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(CounselTheme.inkAccent)
            Text("\(model.totalRedactedCount) to redact")
                .font(.callout).monospacedDigit()
                .foregroundStyle(CounselTheme.textPrimary)

            if model.visibleCount > 0 {
                Text("\u{00B7}  \(model.visibleCount) will remain visible")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(CounselTheme.danger)
            }

            if !model.aiActive {
                // Two different states share this slot and MUST look different.
                // A deliberate patterns-only run is a normal, informational
                // choice. An AI pass that was asked for and could not run is a
                // warning: the user expected names and companies to be found
                // and they were not. Rendering both as the same red triangle
                // makes a failed redaction indistinguishable from an intended
                // one. See docs/design/model-tiers-prd.md section 7.
                if model.aiWarning == nil {
                    Label("Patterns only", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(CounselTheme.textSecondary)
                        .help(L10n.string("Emails, phones, dates, amounts, and ID numbers were detected. Names, companies, and addresses were not, because this detection level does not run the AI model."))
                } else {
                    Label("AI did not run", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(CounselTheme.danger)
                        .help(model.aiWarning ?? "")
                }
            }

            if let warning = model.aiWarning {
                Text("\u{00B7}  \(warning)")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .lineLimit(1)
                    .help(warning)
            }

            if let note = model.learningNote {
                Text("\u{00B7}  \(note)")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            if model.canChooseSealCandidates {
                sealCandidateToggle
            }

            Spacer(minLength: 0)

            if let exportMessage {
                Text(exportMessage)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .lineLimit(1)
            }

            // The active document is reviewed, but unscanned tray partners
            // can still be swept from here.
            if session.entries.count > 1 {
                scanAllButton
            }
            scanButton(title: "Re-scan", prominent: false)
        }
    }

    // MARK: - Seal candidates

    /// The per-document seal candidate choice. Shown only for image
    /// documents, through the model's gate rather than a local condition, so
    /// every entry point agrees on when the choice exists.
    private var sealCandidateToggle: some View {
        Toggle(
            LocalizedStringKey(ImageExportPresentation.sealCandidateToggleTitle),
            isOn: sealCandidateBinding
        )
        .toggleStyle(.checkbox)
        .font(.callout)
        .foregroundStyle(CounselTheme.textSecondary)
        .help(L10n.string(ImageExportPresentation.sealCandidateToggleHelp))
    }

    /// Reads and writes the choice on whichever document is active NOW. The
    /// binding deliberately does not capture the ReviewModel: the tray can
    /// change the active document under an open banner, and a captured model
    /// would keep writing to the document the user left.
    private var sealCandidateBinding: Binding<Bool> {
        Binding(
            get: { session.activeModel.includeSealCandidates },
            set: { session.activeModel.includeSealCandidates = $0 }
        )
    }

    // MARK: - Chrome

    /// Shared banner container chrome. Every banner row ends with the labeled
    /// On-device indicator: the trust claim stays visible in this mode without
    /// spending toolbar width, and the label explains the lock icon.
    private func bannerChrome<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            content()

            Divider().frame(height: 14)

            Label("On-device", systemImage: "lock.laptopcomputer")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(CounselTheme.textSecondary)
                .help(L10n.string("Detection and redaction run on this Mac. A detection-model download uses a network connection while it runs."))
                .accessibilityLabel(Text("On-device detection and redaction"))

            // When the user-presence upgrade failed, say so here rather than
            // letting the On-device badge imply a Touch ID gate that is not
            // there. See KeychainAdvisoryStore.
            if let advisory = keychainAdvisory.advisory {
                Label("Touch ID inactive", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(CounselTheme.danger)
                    .help(advisory)
                    .accessibilityLabel(Text(verbatim: advisory))
            }
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

    // MARK: - Copy

    /// "Spotting PII 42%  ·  about 12s remaining"
    private var detectingLabel: String {
        AnonymizeWorkflowPresentation.detectingLabel(
            progress: model.progress,
            eta: model.etaText
        )
    }

    private var bannerText: String? {
        switch model.status {
        case .idle:
            return exportMessage ?? session.sessionNote
        case .importing:
            return L10n.string("Importing document")
        case .imported:
            // The shipped sentence promises names. With no model on this Mac
            // that is a promise the scan cannot keep, and it is made in the
            // same strip as the button that starts the scan.
            guard hasDetectionModel else {
                return L10n.string("Document ready. Click Scan for PII to spot dates, amounts, emails, phones, and ID numbers. Names and company names need a detection model.")
            }
            return L10n.string("Document ready. Click Scan for PII to spot names, companies, and other personal data.")
        case .detecting:
            return L10n.string("Spotting PII")
        case .ready:
            if let exportMessage { return exportMessage }
            if let note = model.learningNote {
                return String(
                    format: L10n.string("Ready for review. %@."),
                    note as NSString
                )
            }
            return L10n.string("Ready for review")
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
}
