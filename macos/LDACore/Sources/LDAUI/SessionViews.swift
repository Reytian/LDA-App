//
//  SessionViews.swift
//  LDAUI
//
//  Session-level views: the document tray rows shown at the top of the entity
//  sidebar (R19), the add-a-missed-term popover (R5), and the menu-bar
//  companion's clipboard round trip.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
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

            Text(verbatim: name)
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
        .accessibilityLabel(Text(verbatim: String(
            format: L10n.string("Document %@, status %@"),
            name as NSString,
            statusDescription as NSString
        )))
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
                .help(String(
                    format: L10n.string("%lld values will be protected"),
                    Int64(model.redactedCount)
                ))
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
        case .importing: return L10n.string("importing")
        case .detecting: return L10n.string("detecting")
        case .ready:
            return String(
                format: L10n.string("%lld values protected"),
                Int64(model.redactedCount)
            )
        case .failed: return L10n.string("failed")
        case .idle, .imported: return L10n.string("not anonymized yet")
        }
    }
}

// MARK: - Assignable entity kinds

/// The entity kinds a user can assign by hand, shared by the missed-item
/// popover and the vocabulary editor so the two pickers can never drift.
/// Order mirrors ReviewModel.groupTypeOrder; SEAL sits with the other
/// identifier kinds so a stamp or chop mention can be protected manually.
enum AssignableEntityTypes {
    /// Kinds assignable to a manually protected item.
    static let manual: [EntityType] = [
        .person, .company, .address, .email, .phone,
        .bankAccount, .nationalID, .uscc,
        .caseNumber, .licensePlate, .wechatID, .url, .seal,
        .amount, .date
    ]

    /// Kinds assignable to a vocabulary term (adds the neutral bucket).
    static let vocabulary: [EntityType] = manual + [.unknown]
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
    private static let assignableTypes: [EntityType] = AssignableEntityTypes.manual

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
                    Text(EntityTypePresentation.localizedKey(for: kind)).tag(kind)
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
            feedback = String(
                format: L10n.string("\"%@\" was not found in the document (or is already protected)."),
                text as NSString
            )
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
            Text(verbatim: note)
        }

        Divider()

        if let client = session.clientLabel {
            Text(verbatim: String(
                format: L10n.string("Client: %@"),
                client as NSString
            ))
        }
        Text("Detection and redaction run on this Mac.")

        Divider()

        Button("Open LDA") {
            openWindow(id: LDAWindowID.main)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func redactClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            session.companionNote = L10n.string("The clipboard has no text to redact.")
            return
        }
        do {
            let createdAt = ISO8601DateFormatter().string(from: Date())
            let redacted = try session.redactClipboardText(text, createdAtISO8601: createdAt)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(redacted.text, forType: .string)
            if redacted.tokenCount == 0 {
                session.companionNote = L10n.string(
                    "No patterned values found; the clipboard is unchanged in content."
                )
            } else {
                let key = redacted.tokenCount == 1
                    ? "Protected %lld value on the clipboard (patterns only)."
                    : "Protected %lld values on the clipboard (patterns only)."
                session.companionNote = String(
                    format: L10n.string(key),
                    Int64(redacted.tokenCount)
                )
            }
        } catch {
            session.companionNote = String(
                format: L10n.string("Could not redact: %@"),
                error.localizedDescription as NSString
            )
        }
    }

    private func restoreClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            session.companionNote = L10n.string("The clipboard has no text to restore.")
            return
        }
        do {
            guard let restored = try session.restorePasted(text) else {
                session.companionNote = L10n.string(
                    "Nothing to restore against yet. Export for AI first."
                )
                return
            }
            // Restored text is DE-ANONYMIZED client material. It goes on the
            // clipboard marked concealed and transient, and clears itself
            // shortly after, so a forgotten clipboard is not an open-ended
            // exposure to every app on the Mac. See SensitiveClipboard.
            SensitiveClipboard.write(restored.text)
            let restoredKey = restored.restoredCount == 1
                ? "Restored %lld value on the clipboard. %@"
                : "Restored %lld values on the clipboard. %@"
            var note = String(
                format: L10n.string(restoredKey),
                Int64(restored.restoredCount),
                SensitiveClipboard.localizedExpiryNote() as NSString
            )
            let flagged = restored.orphanTokens.count + restored.suspectPlaceholders.count
                + restored.ambiguousReplacements.count
            if flagged > 0 {
                // "item", not "placeholder": a refused mask is counted here
                // too, and it is not a placeholder.
                let flaggedKey = flagged == 1
                    ? " %lld item needs review; use Restore in the app."
                    : " %lld items need review; use Restore in the app."
                note += String(format: L10n.string(flaggedKey), Int64(flagged))
            }
            session.companionNote = note
        } catch {
            session.companionNote = String(
                format: L10n.string("Could not restore: %@"),
                DocumentErrorPresentation.describeOrFallback(error) as NSString
            )
        }
    }
}
