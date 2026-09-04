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
            L10n.button("Remove from Session", role: .destructive) { onRemove() }
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
            // The whole document's coverage, headers and footers included,
            // so the tray chip and the review banner say the same thing.
            Text("\(model.totalRedactedCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(CounselTheme.textSecondary)
                .help(String(
                    format: L10n.string("%lld values will be protected"),
                    Int64(model.totalRedactedCount)
                ))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(CounselTheme.danger)
        case .idle, .imported:
            Image(systemName: "circle.dotted")
                .font(.caption2)
                .foregroundStyle(CounselTheme.textSecondary)
                .l10nHelp("Not anonymized yet")
        }
    }

    private var statusDescription: String {
        switch model.status {
        case .importing: return L10n.string("importing")
        case .detecting: return L10n.string("detecting")
        case .ready:
            return String(
                format: L10n.string("%lld values protected"),
                Int64(model.totalRedactedCount)
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

// MARK: - Add a missed term (R5) and the Protect chooser

/// The kind chooser behind every Protect action. Two modes share one popover:
/// the typed path ("Protect a missed item": type or paste the exact text) and
/// the selection path (the trimmed selection is fixed, the guessed kind is
/// preselected, and the primary button carries the occurrence count or the
/// retype / re-accept wording). Kinds are listed in AssignableEntityTypes
/// order with their hue dots, so the chooser doubles as a legend.
struct AddTermPopover: View {
    @ObservedObject var model: ReviewModel
    @Binding var isPresented: Bool

    /// The trimmed selection to protect, or nil for the typed path.
    let selection: String?
    /// The window's undo manager, so the action lands in Edit > Undo.
    let undoManager: UndoManager?

    @State private var text: String
    @State private var type: EntityType
    @State private var feedback: String?

    init(
        model: ReviewModel,
        isPresented: Binding<Bool>,
        selection: String? = nil,
        undoManager: UndoManager? = nil
    ) {
        _model = ObservedObject(wrappedValue: model)
        _isPresented = isPresented
        let trimmed = selection.map(ProtectSelectionRules.trim).flatMap { $0.isEmpty ? nil : $0 }
        self.selection = trimmed
        self.undoManager = undoManager
        _text = State(initialValue: trimmed ?? "")
        _type = State(initialValue: trimmed.map { ManualTypeGuess.guess(for: $0) } ?? .person)
    }

    /// What already exists for the value being protected.
    private var variant: ProtectVariant {
        model.protectVariant(for: selection ?? text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var occurrences: Int {
        if case .protect(let count) = variant { return count }
        return model.occurrenceCount(of: selection ?? text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection {
                Text(verbatim: ProtectSelectionPresentation.chooserTitle(value: selection, variant: variant))
                    .font(.headline)
                    .foregroundStyle(CounselTheme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Text(verbatim: ProtectSelectionPresentation.chooserSubtitle(occurrences: occurrences))
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
            } else {
                L10n.text("Protect a missed item")
                    .font(.headline)
                    .foregroundStyle(CounselTheme.textPrimary)

                L10n.text("Type the exact text as it appears in the document. Every occurrence will be redacted.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                L10n.textField("Exact text", text: $text)
                    .textFieldStyle(.roundedBorder)
            }

            L10n.text("Kind")
                .font(.caption.weight(.semibold))
                .foregroundStyle(CounselTheme.textSecondary)

            kindGrid

            if let feedback {
                Text(verbatim: feedback)
                    .font(.callout)
                    .foregroundStyle(CounselTheme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                L10n.button("Cancel", role: .cancel) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button {
                    confirm()
                } label: {
                    Text(verbatim: primaryTitle)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(CounselTheme.inkAccentFill)
                .disabled(isPrimaryDisabled)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    /// Two columns of kinds, each with its hue dot; the selected one is marked.
    private var kindGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), alignment: .topLeading),
                GridItem(.flexible(), alignment: .topLeading)
            ],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(AssignableEntityTypes.manual, id: \.self) { kind in
                Button {
                    type = kind
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: type == kind ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(type == kind ? CounselTheme.inkAccent : CounselTheme.textSecondary)
                        Circle()
                            .fill(CounselTheme.color(for: kind))
                            .frame(width: 8, height: 8)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        Text(EntityTypePresentation.localizedKey(for: kind))
                            .font(.callout)
                            .foregroundStyle(CounselTheme.textPrimary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(EntityTypePresentation.localizedKey(for: kind)))
                .accessibilityAddTraits(type == kind ? [.isSelected] : [])
            }
        }
    }

    private var primaryTitle: String {
        guard selection != nil else { return L10n.string("Protect") }
        return ProtectSelectionPresentation.chooserAction(
            variant: variant,
            chosen: type,
            occurrences: occurrences
        )
    }

    private var isPrimaryDisabled: Bool {
        if selection != nil {
            if case .protect(let count) = variant { return count == 0 }
            return false
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func confirm() {
        if let selection {
            let outcome = model.protectValue(selection, type: type, undoManager: undoManager)
            guard outcome.refusal != .emptySelection else {
                feedback = String(
                    format: L10n.string("\"%@\" was not found in the document (or is already protected)."),
                    selection as NSString
                )
                return
            }
            // Anything else (protected, or a block the notice row explains).
            isPresented = false
            return
        }
        let added = model.addManualEntity(text: text, type: type, undoManager: undoManager)
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
        L10n.button("Redact Clipboard") {
            redactClipboard()
        }
        .l10nHelp("Replace sensitive values in the clipboard text with placeholders")

        L10n.button("Restore Clipboard") {
            restoreClipboard()
        }
        .l10nHelp("Restore the real values in the AI output on the clipboard")

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
        L10n.text("Detection and redaction run on this Mac.")

        Divider()

        L10n.button("Open LDA") {
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
