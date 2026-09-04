//
//  DocumentPane.swift
//  LDAUI
//
//  The paper-forward document pane: the serif reading surface where the
//  imported text is shown with review highlights, and a Safe Preview mode that
//  renders the actual protected body text before the user exports it.
//
//  Rendering model:
//  - The text is rendered by DocumentTextView, an NSTextView inside its own
//    scroll view, so the user can select text and the selection range (UTF-16,
//    the Span convention) reaches the model for "Protect as <kind>".
//  - Styling is a pure function (DocumentTextStyler): the underline carries
//    the type hue in both review states, the fill carries state, Safe Preview
//    tokens take the type hue in the monospaced chip face, and every highlight
//    has a tooltip. The styled strings are cached here and rebuilt only when
//    the text or the entity list changes, never on progress ticks.
//  - The preview mode lives on the ReviewModel so the menus and the sidebar
//    footer agree with the picker; a scan that finishes flips it to Safe
//    Preview, and Safe Preview clears the selection because it is not
//    selectable.
//  - A transient notice row under the header confirms or explains a Protect
//    action, with Undo, Change Kind, or Protect Anyway.
//
//  While the document is empty or the session is still importing, a graceful
//  placeholder or the drop zone is shown instead of the reading column.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

/// The document review pane. Renders the paper-styled, selectable text surface
/// with entity highlights and sealed token chips, and a drag-and-drop intake
/// zone before any document is open. Dropping files (or a .zip) at any time
/// adds them to the session's tray (R19).
public struct DocumentPane: View {
    @ObservedObject private var session: SessionModel
    @ObservedObject private var model: ReviewModel

    /// The window's undo manager, so a Protect action lands in Edit > Undo.
    @Environment(\.undoManager) private var undoManager

    /// True while a draggable document hovers over the drop zone.
    @State private var isDropTargeted = false

    /// The styled Original text, rebuilt only when the text or the entity
    /// list changes. Without this cache the pane re-styled the full document
    /// on EVERY published model change, including each progress tick during
    /// detection, which stalls the window on long documents.
    @State private var styledDocument = NSAttributedString()

    /// The tokenized Safe Preview text, rebuilt with the entity list.
    @State private var safePreviewDocument = NSAttributedString()

    /// True while the pointer rests on the notice row (pauses auto-dismiss).
    @State private var isNoticeHovered = false

    /// True while the Change Kind chooser is presented from the notice row.
    @State private var isChangingKind = false

    /// True when the hosting window is narrow (WindowLayoutPolicy); the
    /// legend then collapses to its menu button like the rest of the chrome.
    @State private var isWindowNarrow = false

    /// The measured width of the header's content row, for the legend tier.
    @State private var headerWidth: CGFloat = 0

    public init(session: SessionModel, model: ReviewModel) {
        self.session = session
        self.model = model
    }

    public var body: some View {
        ZStack {
            CounselTheme.paper

            if isBusy {
                progressPlaceholder
            } else if model.documentText.isEmpty {
                dropZone
            } else {
                readingColumn
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole pane accepts document drops at any time; new files join
        // the session tray alongside what is already open.
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            openURLs(urls)
            return true
        } isTargeted: { _ in }
        .onAppear {
            restyle()
        }
        .onChange(of: model.documentText) { _, _ in
            restyle()
        }
        .onChange(of: model.entities) { _, entities in
            restyle()
            dismissNotice(ifSupersededBy: entities)
        }
        .onChange(of: model.status) { _, status in
            switch status {
            case .ready:
                model.previewMode = .safePreview
            case .idle, .importing, .imported:
                model.previewMode = .original
            case .detecting, .failed:
                break
            }
        }
        .onChange(of: model.previewMode) { _, mode in
            // Safe Preview is not selectable, so no selection can exist there.
            if !mode.allowsTextSelection {
                model.selectedTextRange = nil
            }
        }
        .onChange(of: model.protectNotice?.id) { _, _ in
            announceNotice()
        }
    }

    /// Rebuild both styled surfaces from the current text and entities.
    private func restyle() {
        styledDocument = DocumentTextStyler.styledOriginal(
            text: model.documentText,
            entities: model.entities
        )
        let preview = ReviewModel.redactedPreviewText(
            text: model.documentText,
            entities: model.entities,
            style: model.outputStyleProvider()
        )
        safePreviewDocument = DocumentTextStyler.styledSafePreview(text: preview)
    }

    // MARK: - Drop zone (empty state)

    /// The first-run intake: a dashed drop target plus a Choose File button.
    /// Accepts a dragged document or a click to browse.
    private var dropZone: some View {
        VStack(spacing: 18) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(CounselTheme.inkAccent.opacity(0.85))

            VStack(spacing: 6) {
                L10n.text("Drop documents to anonymize")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                L10n.text("PDF, Word (.docx), plain text, or a .zip of them. Several files become one session. Detection and redaction run on this Mac.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .multilineTextAlignment(.center)

            Button {
                presentOpenPanel()
            } label: {
                L10n.text("Choose Files")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccentFill)

            if case .failed(let detail) = model.status {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(CounselTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: 440)
        .padding(48)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(CounselTheme.raised.opacity(isDropTargeted ? 1.0 : 0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isDropTargeted ? CounselTheme.inkAccent : CounselTheme.hairline,
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1.5, dash: [9, 7])
                )
        )
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { presentOpenPanel() }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            openURLs(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .accessibilityElement(children: .combine)
        .l10nAccessibilityLabel("Drop documents to anonymize, or choose files")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Open

    /// Present a native open panel and add the chosen documents to the session.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.openContentTypes
        panel.message = L10n.string("Choose .txt, .docx, .pdf documents, .png or .jpg evidence images, or a .zip of them. Several files become one session.")
        panel.prompt = L10n.string("Open")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        openURLs(panel.urls)
    }

    /// Add document URLs (from a drop or the panel) to the session's tray.
    private func openURLs(_ urls: [URL]) {
        let scoped = urls.map { (url: $0, needsScope: $0.startAccessingSecurityScopedResource()) }
        Task {
            // defer releases the sandbox scopes even if the Task is cancelled
            // mid-import; leaking one can make later opens of the same URL fail.
            defer {
                for item in scoped where item.needsScope {
                    item.url.stopAccessingSecurityScopedResource()
                }
            }
            await session.addDocuments(urls)
        }
    }

    /// The document types accepted for opening: plain text, Word, PDF, zip,
    /// and evidence images (PNG and JPEG).
    private static let openContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .pdf, .zip, .png, .jpeg]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        return types
    }()

    // MARK: - Reading column

    /// The preview header, the transient notice, and the selectable text.
    private var readingColumn: some View {
        VStack(spacing: 0) {
            previewHeader

            if let notice = model.protectNotice {
                noticeRow(notice)
            }

            DocumentTextView(
                content: model.previewMode == .original ? styledDocument : safePreviewDocument,
                isSelectable: model.previewMode.allowsTextSelection,
                menuContext: menuContext,
                chooserRequestToken: model.protectSelectionRequestToken,
                makeChooser: { dismiss in AnyView(chooser(dismiss: dismiss)) },
                onSelectionChange: { range in model.selectedTextRange = range },
                onCancel: { model.protectNotice = nil }
            )
        }
    }

    private var previewHeader: some View {
        HStack(spacing: HeaderLayout.spacing) {
            L10n.picker("Document preview", selection: $model.previewMode) {
                ForEach(DocumentPreviewMode.allCases, id: \.self) { mode in
                    L10n.text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: HeaderLayout.pickerWidth)

            if model.previewMode == .safePreview {
                if model.visibleCount > 0 {
                    L10n.label(
                        "%lld kept visible",
                        systemImage: "eye.trianglebadge.exclamationmark",
                        model.visibleCount
                    )
                    .foregroundStyle(CounselTheme.danger)
                    .l10nHelp("Items you rejected remain readable in this preview and in the saved document")
                } else {
                    L10n.label("Accepted findings replaced", systemImage: "checkmark.shield")
                        .foregroundStyle(CounselTheme.textSecondary)
                }
            } else if model.entities.isEmpty {
                // The legend replaces this caption as soon as findings exist.
                L10n.text("Original text with review highlights")
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            Spacer(minLength: 0)

            DocumentLegend(
                model: model,
                isNarrow: isWindowNarrow,
                availableWidth: legendAvailableWidth
            )
        }
        .font(.callout)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: HeaderWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(HeaderWidthKey.self) { headerWidth = $0 }
        .background(WindowNarrownessReader(isNarrow: $isWindowNarrow).frame(width: 0, height: 0))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
    }

    /// The room left for the legend after the picker and the status label.
    private var legendAvailableWidth: CGFloat {
        let statusWidth = model.previewMode == .safePreview ? HeaderLayout.safePreviewLabelEstimate : 0
        return max(0, headerWidth - HeaderLayout.pickerWidth - statusWidth - 2 * HeaderLayout.spacing)
    }

    // MARK: - Protect Selection wiring

    /// What the text view needs to build its Protect menu items.
    private var menuContext: DocumentTextMenuContext {
        DocumentTextMenuContext(
            isOriginalVisible: model.previewMode == .original,
            canProtect: model.canProtectText,
            assignableTypes: AssignableEntityTypes.manual,
            guess: { ManualTypeGuess.guess(for: $0) },
            onProtect: { type in protectCurrentSelection(as: type) },
            onShowOriginal: { model.previewMode = .original }
        )
    }

    /// Protect whatever is selected right now as `type` (context menu path).
    private func protectCurrentSelection(as type: EntityType) {
        guard let range = model.selectedTextRange else { return }
        model.protectSelection(range: range, type: type, undoManager: undoManager)
    }

    /// The kind chooser for the current selection (Review menu path).
    private func chooser(dismiss: @escaping () -> Void) -> some View {
        AddTermPopover(
            model: model,
            isPresented: Binding(get: { true }, set: { if !$0 { dismiss() } }),
            selection: model.selectedText,
            undoManager: undoManager
        )
    }

    // MARK: - Notice row

    /// The transient confirmation or explanation after a Protect action.
    private func noticeRow(_ notice: ProtectNotice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: notice.canUndo ? "checkmark.shield" : "info.circle")
                .foregroundStyle(notice.canUndo ? CounselTheme.inkAccent : CounselTheme.textSecondary)
                .accessibilityHidden(true)

            Text(verbatim: notice.message)
                .font(.callout)
                .foregroundStyle(CounselTheme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if notice.offersProtectAnyway {
                L10n.button("Protect Anyway") {
                    model.protectValue(
                        notice.value,
                        type: notice.type,
                        undoManager: undoManager,
                        allowRoleLabel: true
                    )
                }
                .buttonStyle(.borderless)
            }

            if notice.canUndo, undoManager != nil {
                L10n.button("Undo") {
                    undoManager?.undo()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: String(
                    format: L10n.string("Undo protecting %@"),
                    notice.value as NSString
                )))
            }

            if notice.canChangeKind {
                L10n.button("Change Kind") {
                    isChangingKind = true
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(verbatim: String(
                    format: L10n.string("Change the kind for %@"),
                    notice.value as NSString
                )))
                .popover(isPresented: $isChangingKind, arrowEdge: .bottom) {
                    AddTermPopover(
                        model: model,
                        isPresented: $isChangingKind,
                        selection: notice.value,
                        undoManager: undoManager
                    )
                }
            }

            Button {
                model.protectNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .buttonStyle(.borderless)
            .l10nAccessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
        .onHover { isNoticeHovered = $0 }
        .task(id: notice.id) {
            await autoDismiss(notice)
        }
    }

    /// Dismiss the notice after a few seconds, waiting while it is hovered.
    private func autoDismiss(_ notice: ProtectNotice) async {
        try? await Task.sleep(for: .seconds(NoticeTiming.autoDismissSeconds))
        while isNoticeHovered, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(NoticeTiming.hoverPollSeconds))
        }
        guard !Task.isCancelled, model.protectNotice?.id == notice.id else { return }
        model.protectNotice = nil
    }

    /// A later change to the entity list supersedes the notice.
    private func dismissNotice(ifSupersededBy entities: [ReviewEntity]) {
        guard let notice = model.protectNotice else { return }
        if Set(entities.map(\.id)) != notice.entityIDs {
            model.protectNotice = nil
        }
    }

    /// Announce a successful protection to VoiceOver (the row is otherwise silent).
    private func announceNotice() {
        guard let announcement = model.protectNotice?.announcement else { return }
        AccessibilityNotification.Announcement(announcement).post()
    }

    // MARK: - Busy placeholder

    /// True only while importing (before any text exists). During detection the
    /// imported text stays visible and the progress bar lives in the banner.
    private var isBusy: Bool {
        if case .importing = model.status { return true }
        return false
    }

    /// A graceful placeholder shown during import.
    private var progressPlaceholder: some View {
        VStack(spacing: NoticeTiming.placeholderSpacing) {
            ProgressView()
                .controlSize(.small)
                .tint(CounselTheme.inkAccent)

            L10n.text("Importing document")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(DocumentTextLayout.gutter)
    }

    // MARK: - Constants

    private enum HeaderLayout {
        /// The segmented Original / Safe Preview picker.
        static let pickerWidth: CGFloat = 250
        /// Spacing between the header's elements.
        static let spacing: CGFloat = 14
        /// Room reserved for the Safe Preview status label beside the legend.
        static let safePreviewLabelEstimate: CGFloat = 220
    }

    private enum NoticeTiming {
        /// How long a notice stays before dismissing itself.
        static let autoDismissSeconds: Double = 6
        /// How often a hovered notice re-checks whether the pointer left.
        static let hoverPollSeconds: Double = 1
        /// Vertical spacing inside the placeholder stack.
        static let placeholderSpacing: CGFloat = 12
    }
}

/// The measured width of the preview header's content row.
private struct HeaderWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The two surfaces of the document pane. Public because the ReviewModel owns
/// the current mode (the selection gate and the menus read it).
public enum DocumentPreviewMode: String, CaseIterable {
    case original = "Original"
    case safePreview = "Safe Preview"


    var allowsTextSelection: Bool { self == .original }
}
