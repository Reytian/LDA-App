//
//  SessionViews.swift
//  LDAUI
//
//  Session-level views: the document tray rows shown at the top of the entity
//  sidebar (R19), the add-a-missed-term popover (R5), and the paste-and-
//  restore sheet that closes the AI round-trip (framework stage 4).
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

// MARK: - Document tray row

/// One tray row: the document name, a quiet status glyph, and the redaction
/// count once review is ready. Selection routes through the session.
struct DocumentTrayRow: View {
    @ObservedObject var model: ReviewModel
    let name: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.caption)
                .foregroundStyle(isSelected ? CounselTheme.inkAccent : CounselTheme.textSecondary)

            Text(name)
                .font(.callout)
                .foregroundStyle(CounselTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 6)

            statusGlyph
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Remove from Session", role: .destructive) { onRemove() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(name), \(statusDescription)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch model.status {
        case .importing, .detecting:
            ProgressView()
                .controlSize(.mini)
        case .ready:
            Text("\(model.redactedCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(CounselTheme.textSecondary)
                .help("\(model.redactedCount) values will be protected")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(CounselTheme.danger)
        case .idle, .imported:
            Image(systemName: "circle.dotted")
                .font(.caption2)
                .foregroundStyle(CounselTheme.textSecondary)
                .help("Not anonymized yet")
        }
    }

    private var statusDescription: String {
        switch model.status {
        case .importing: return "importing"
        case .detecting: return "detecting"
        case .ready: return "\(model.redactedCount) values protected"
        case .failed: return "failed"
        case .idle, .imported: return "not anonymized yet"
        }
    }
}

// MARK: - Add a missed term (R5)

/// A small popover to protect a value the detector missed: type or paste the
/// exact text, choose its kind, and every occurrence is added for redaction.
struct AddTermPopover: View {
    @ObservedObject var model: ReviewModel
    @Binding var isPresented: Bool

    @State private var text = ""
    @State private var type: EntityType = .person
    @State private var feedback: String?

    /// The kinds a user can assign by hand.
    private static let assignableTypes: [EntityType] = [
        .person, .company, .address, .email, .phone,
        .bankAccount, .nationalID, .uscc, .amount, .date
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Protect a missed item")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            Text("Type the exact text as it appears in the document. Every occurrence will be redacted.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Exact text", text: $text)
                .textFieldStyle(.roundedBorder)

            Picker("Kind", selection: $type) {
                ForEach(Self.assignableTypes, id: \.self) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }

            if let feedback {
                Text(feedback)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Protect") { add() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func add() {
        let added = model.addManualEntity(text: text, type: type)
        if added > 0 {
            isPresented = false
        } else {
            feedback = "\"\(text)\" was not found in the document (or is already protected)."
        }
    }
}

// MARK: - Menu-bar companion

/// Stable SwiftUI scene identifiers shared by the app entry point and the
/// menu-bar companion.
public enum LDAWindowID {
    public static let main = "main"
}

/// The menu-bar companion (auxiliary posture): quick clipboard redact and the
/// no-dead-end "restore the clipboard" for coming back from the AI.
public struct CompanionMenu: View {
    @ObservedObject var session: SessionModel
    @Environment(\.openWindow) private var openWindow

    public init(session: SessionModel) {
        self.session = session
    }

    public var body: some View {
        Button("Redact Clipboard") {
            redactClipboard()
        }
        .help("Replace sensitive values in the clipboard text with placeholders")

        Button("Restore Clipboard") {
            restoreClipboard()
        }
        .help("Restore the real values in the AI output on the clipboard")

        if let note = session.companionNote {
            Divider()
            Text(note)
        }

        Divider()

        if let client = session.clientLabel {
            Text("Client: \(client)")
        }
        Text("On-device. Nothing leaves this Mac.")

        Divider()

        Button("Open LDA") {
            openWindow(id: LDAWindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func redactClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            session.companionNote = "The clipboard has no text to redact."
            return
        }
        do {
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let redacted = try session.redactClipboardText(text, createdAtISO8601: createdAt)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(redacted.text, forType: .string)
            session.companionNote = redacted.tokenCount == 0
                ? "No patterned values found; the clipboard is unchanged in content."
                : "Protected \(redacted.tokenCount) value"
                    + (redacted.tokenCount == 1 ? "" : "s")
                    + " on the clipboard (patterns only)."
        } catch {
            session.companionNote = "Could not redact: \(error.localizedDescription)"
        }
    }

    private func restoreClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            session.companionNote = "The clipboard has no text to restore."
            return
        }
        do {
            guard let restored = try session.restorePasted(text) else {
                session.companionNote = "Nothing to restore against yet. Copy for AI first."
                return
            }
            // Restored text is DE-ANONYMIZED client material. It goes on the
            // clipboard marked concealed and transient, and clears itself
            // shortly after, so a forgotten clipboard is not an open-ended
            // exposure to every app on the Mac. See SensitiveClipboard.
            SensitiveClipboard.write(restored.text)
            var note = "Restored \(restored.restoredCount) value"
                + (restored.restoredCount == 1 ? "" : "s")
                + " on the clipboard. "
                + SensitiveClipboard.expiryNote
            let flagged = restored.orphanTokens.count + restored.suspectPlaceholders.count
            if flagged > 0 {
                note += " \(flagged) placeholder"
                    + (flagged == 1 ? " needs" : "s need")
                    + " review; use Restore from AI in the app."
            }
            session.companionNote = note
        } catch {
            session.companionNote = "Could not restore: \(error.localizedDescription)"
        }
    }
}

// MARK: - Paste and restore sheet (stage 4)

/// The bring-back half of the round-trip: paste the AI's output, restore the
/// real values against the session mapping, review what matched (orphans and
/// damaged placeholders are flagged, never guessed), and save the final file.
struct PasteRestoreSheet: View {
    @ObservedObject var session: SessionModel
    @Binding var isPresented: Bool

    @State private var pasted = ""
    @State private var result: RestoreResult?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bring back the AI's answer")
                .font(.headline)
                .foregroundStyle(CounselTheme.textPrimary)

            Text("Paste what the AI returned. The protected values are restored on this Mac; "
                + "anything that cannot be matched with certainty is flagged, never guessed.")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $pasted)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(CounselTheme.hairline, lineWidth: 1)
                )

            HStack {
                Button("Paste from Clipboard") {
                    if let clip = NSPasteboard.general.string(forType: .string) {
                        pasted = clip
                    }
                }
                Spacer()
            }

            if let result {
                resultSummary(result)
            }
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Close", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Restore") { restore() }
                    .disabled(pasted.isEmpty)
                Button("Save Restored\u{2026}") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(CounselTheme.inkAccentFill)
                    .disabled(result == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 460)
        .background(CounselTheme.raised)
    }

    // MARK: - Result summary

    @ViewBuilder
    private func resultSummary(_ result: RestoreResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "\(result.restoredCount) value" + (result.restoredCount == 1 ? "" : "s") + " restored.",
                systemImage: result.restoredCount > 0 ? "checkmark.seal" : "info.circle"
            )
            .font(.callout)
            .foregroundStyle(CounselTheme.textPrimary)

            if !result.orphanTokens.isEmpty {
                Label(
                    "\(result.orphanTokens.count) unknown placeholder"
                        + (result.orphanTokens.count == 1 ? "" : "s")
                        + " left in place: "
                        + result.orphanTokens.prefix(5).joined(separator: ", "),
                    systemImage: "questionmark.diamond"
                )
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
            }

            if !result.suspectPlaceholders.isEmpty {
                Label(
                    "\(result.suspectPlaceholders.count) placeholder"
                        + (result.suspectPlaceholders.count == 1 ? " looks" : "s look")
                        + " damaged by the AI: "
                        + result.suspectPlaceholders.prefix(5).joined(separator: ", ")
                        + ". Fix them in the text above and restore again.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(CounselTheme.danger)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func restore() {
        errorText = nil
        do {
            guard let restored = try session.restorePasted(pasted) else {
                errorText = "There is nothing to restore against yet. "
                    + "Use Copy for AI first (or pick this session's client profile)."
                return
            }
            result = restored
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save() {
        guard let result else { return }
        let panel = NSSavePanel()
        panel.message = "Save the restored document."
        var types: [UTType] = []
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        types.append(.plainText)
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        panel.allowedContentTypes = types
        panel.nameFieldStringValue = defaultSaveName()
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            if url.pathExtension.lowercased() == "docx" {
                // The agreed fidelity floor: a clean regenerated Word document.
                try SimpleDocxWriter.write(result.text, to: url)
            } else {
                try TextDocumentIO.exportText(result.text, to: url)
            }
            isPresented = false
        } catch {
            errorText = "Could not save: \(error.localizedDescription)"
        }
    }

    /// Default save name: the active document's base name. A .docx original
    /// offers a Word file back (the original-format round-trip); everything
    /// else offers Markdown.
    private func defaultSaveName() -> String {
        guard let entry = session.activeEntry else { return "restored.md" }
        let base = entry.url.deletingPathExtension().lastPathComponent
        let ext = entry.url.pathExtension.lowercased() == "docx" ? "docx" : "md"
        return "\(base)_restored.\(ext)"
    }
}
