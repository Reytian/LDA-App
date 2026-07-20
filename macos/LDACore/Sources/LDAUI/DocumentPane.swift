//
//  DocumentPane.swift
//  LDAUI
//
//  The paper-forward document pane: the serif edit surface where the imported
//  text is shown with faint entity tint highlights and colored underlines, and
//  accepted entities are highlighted for review. A Safe Preview mode renders
//  the actual tokenized body text before the user copies or saves it.
//
//  Rendering model:
//  - The full document text is shown as a serif body on the paper surface,
//    inside a vertically scrolling reading column capped at a comfortable
//    measure and centered with generous gutters.
//  - Each entity's span is visually marked by building one AttributedString from
//    the document text and applying, over each span's UTF-16 range, a faint tint
//    background plus a colored underline in the entity's Counsel hue.
//  - Safe Preview replaces accepted values with opaque placeholders and leaves
//    rejected values visible, using the same tokenization rules as export.
//  - Spans are applied from the end of the document toward the start so that the
//    UTF-16 to AttributedString index mapping stays valid as attributes are set.
//
//  While the document is empty or the session is still importing or detecting, a
//  graceful placeholder with a ProgressView and the current status is shown
//  instead of the (empty) reading column.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LDACore

/// The document review pane. Renders the editable, paper-styled text surface
/// with entity highlights and sealed token chips, and a drag-and-drop intake
/// zone before any document is open. Dropping files (or a .zip) at any time
/// adds them to the session's tray (R19).
public struct DocumentPane: View {
    @ObservedObject private var session: SessionModel
    @ObservedObject private var model: ReviewModel

    /// True while a draggable document hovers over the drop zone.
    @State private var isDropTargeted = false

    /// The plain document text as an AttributedString, rebuilt only when the
    /// text itself changes. Kept separate from the styled copy so an entity
    /// toggle never re-parses the whole document.
    @State private var baseDocument = AttributedString("")

    /// The styled document (base plus entity highlights), rebuilt only when
    /// the text or the entity list changes. Without this cache the computed
    /// property re-built the full AttributedString on EVERY published model
    /// change, including each progress tick during detection, which stalls
    /// the window on long documents.
    @State private var styledDocument = AttributedString("")

    /// The tokenized body shown by Safe Preview, rebuilt with the entity list.
    @State private var safePreviewDocument = AttributedString("")

    /// Original review surface or the protected text that will be shared.
    @State private var previewMode: DocumentPreviewMode = .original

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
            rebuildBase()
        }
        .onChange(of: model.documentText) { _, _ in
            rebuildBase()
        }
        .onChange(of: model.entities) { _, newEntities in
            restyle(entities: newEntities)
        }
        .onChange(of: model.status) { _, status in
            switch status {
            case .ready:
                previewMode = .safePreview
            case .idle, .importing, .imported:
                previewMode = .original
            case .detecting, .failed:
                break
            }
        }
    }

    /// Re-parse the document text and re-apply the current entity styling.
    private func rebuildBase() {
        baseDocument = AttributedString(model.documentText)
        restyle(entities: model.entities)
    }

    /// Apply entity styling onto a copy of the cached base document.
    private func restyle(entities: [ReviewEntity]) {
        styledDocument = Self.applyEntityStyles(
            base: baseDocument,
            text: model.documentText,
            entities: entities
        )
        let preview = ReviewModel.redactedPreviewText(
            text: model.documentText,
            entities: entities
        )
        safePreviewDocument = Self.styleTokenLiterals(in: preview)
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
                Text("Drop documents to anonymize")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("PDF, Word (.docx), plain text, or a .zip of them. "
                    + "Several files become one session. Everything stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .multilineTextAlignment(.center)

            Button {
                presentOpenPanel()
            } label: {
                Text("Choose Files")
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
        .accessibilityLabel("Drop documents to anonymize, or choose files")
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
        panel.message = "Choose .txt, .docx, .pdf documents, or a .zip of them. Several files become one session."
        panel.prompt = "Open"
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

    /// The document types accepted for opening: plain text, Word, PDF, and zip.
    private static let openContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .pdf, .zip]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        return types
    }()

    // MARK: - Reading column

    /// The preview switch plus a scrolling, width-capped reading column.
    private var readingColumn: some View {
        VStack(spacing: 0) {
            previewHeader

            ScrollView(.vertical) {
                Text(previewMode == .original ? styledDocument : safePreviewDocument)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                    .modifier(PreviewTextSelection(
                        enabled: previewMode.allowsTextSelection
                    ))
                    .lineSpacing(Layout.lineSpacing)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: Layout.columnWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, Layout.gutter)
                    .padding(.vertical, Layout.columnVerticalInset)
            }
        }
    }

    private var previewHeader: some View {
        HStack(spacing: 14) {
            Picker("Document preview", selection: $previewMode) {
                ForEach(DocumentPreviewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 250)

            if previewMode == .safePreview {
                if model.visibleCount > 0 {
                    Label(
                        "\(model.visibleCount) kept visible",
                        systemImage: "eye.trianglebadge.exclamationmark"
                    )
                    .foregroundStyle(CounselTheme.danger)
                    .help("Items you rejected remain readable in this preview and in the saved document")
                } else {
                    Label("Accepted findings replaced", systemImage: "checkmark.shield")
                        .foregroundStyle(CounselTheme.textSecondary)
                }
            } else {
                Text("Original text with review highlights")
                    .foregroundStyle(CounselTheme.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(CounselTheme.raised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(CounselTheme.hairline).frame(height: 1)
        }
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
        VStack(spacing: Layout.placeholderSpacing) {
            ProgressView()
                .controlSize(.small)
                .tint(CounselTheme.inkAccent)

            Text("Importing document")
                .font(.callout)
                .foregroundStyle(CounselTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Layout.gutter)
    }

    // MARK: - Attributed document

    /// Build the attributed document from scratch. Pure and side-effect free.
    /// Kept as the single-call entry point for tests and previews; the view
    /// itself uses the cached base + applyEntityStyles split.
    static func makeAttributed(
        text: String,
        entities: [ReviewEntity]
    ) -> AttributedString {
        applyEntityStyles(base: AttributedString(text), text: text, entities: entities)
    }

    /// Apply entity styling onto a copy of an already-parsed base document.
    /// Spans are applied back to front so the UTF-16 to AttributedString index
    /// mapping computed against the original text stays valid for every span.
    static func applyEntityStyles(
        base: AttributedString,
        text: String,
        entities: [ReviewEntity]
    ) -> AttributedString {
        var attributed = base

        let utf16 = text.utf16
        let total = utf16.count

        let ordered = entities.sorted { $0.span.start > $1.span.start }

        for entity in ordered {
            let span = entity.span
            guard span.start >= 0, span.end <= total, span.start < span.end else {
                continue
            }
            guard let range = attributedRange(
                start: span.start,
                end: span.end,
                in: text,
                attributed: attributed
            ) else {
                continue
            }
            apply(entity: entity, to: &attributed, range: range)
        }

        return attributed
    }

    /// Style placeholder literals in the protected preview without changing
    /// its text. Token detection uses the same grammar as restore.
    private static func styleTokenLiterals(in text: String) -> AttributedString {
        var attributed = AttributedString(text)
        guard let regex = try? NSRegularExpression(
            pattern: TokenGrammar.placeholderPattern
        ) else { return attributed }

        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        for match in matches {
            guard let range = attributedRange(
                start: match.range.location,
                end: match.range.location + match.range.length,
                in: text,
                attributed: attributed
            ) else { continue }
            attributed[range].font = .system(.body, design: .monospaced)
            attributed[range].foregroundColor = CounselTheme.textPrimary
            attributed[range].backgroundColor = CounselTheme.inkAccent.opacity(0.14)
        }
        return attributed
    }

    /// Map a UTF-16 [start, end) offset pair onto a range inside the attributed
    /// string. Returns nil when the offsets do not land on valid String indices,
    /// for example when they split a surrogate pair.
    private static func attributedRange(
        start: Int,
        end: Int,
        in text: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        let utf16 = text.utf16

        guard
            let startUTF16 = utf16.index(
                utf16.startIndex,
                offsetBy: start,
                limitedBy: utf16.endIndex
            ),
            let endUTF16 = utf16.index(
                utf16.startIndex,
                offsetBy: end,
                limitedBy: utf16.endIndex
            ),
            let lower = startUTF16.samePosition(in: text),
            let upper = endUTF16.samePosition(in: text)
        else {
            return nil
        }

        return Range<AttributedString.Index>(lower..<upper, in: attributed)
    }

    /// Apply the highlight or sealed-token styling for one entity over a range.
    private static func apply(
        entity: ReviewEntity,
        to attributed: inout AttributedString,
        range: Range<AttributedString.Index>
    ) {
        let hue = CounselTheme.color(for: entity.span.type)

        if entity.accepted {
            // Sealed token: stronger low-opacity fill in the entity hue and a
            // monospaced face so it reads as a filled chip carrying its token.
            // Token text uses primary ink (not the hue) so it clears WCAG AA;
            // the hue stays in the fill.
            attributed[range].backgroundColor = hue.opacity(Style.sealedFillOpacity)
            attributed[range].foregroundColor = CounselTheme.textPrimary
            attributed[range].font = .system(.body, design: .monospaced)
            attributed[range].underlineStyle = nil
        } else {
            // Candidate highlight: faint tint background plus a colored underline
            // in the entity hue.
            attributed[range].backgroundColor = hue.opacity(Style.tintOpacity)
            attributed[range].underlineStyle = .single
            attributed[range].appKit.underlineColor = NSColor(hue)
        }
    }

    // MARK: - Layout and style constants

    private enum Layout {
        /// The capped reading measure for the serif body column.
        static let columnWidth: CGFloat = 680
        /// Minimum horizontal gutter on each side of the column.
        static let gutter: CGFloat = 48
        /// Vertical inset above and below the column body.
        static let columnVerticalInset: CGFloat = 56
        /// Extra leading between wrapped lines of serif body text.
        static let lineSpacing: CGFloat = 6
        /// Vertical spacing inside the placeholder stack.
        static let placeholderSpacing: CGFloat = 12
    }

    private enum Style {
        /// Background opacity for a faint candidate tint.
        static let tintOpacity: Double = 0.10
        /// Background opacity for a sealed (accepted) token chip fill.
        static let sealedFillOpacity: Double = 0.20
        /// Foreground opacity for sealed token text, keeping it legible.
        static let sealedTextOpacity: Double = 0.95
    }
}

enum DocumentPreviewMode: String, CaseIterable {
    case original = "Original"
    case safePreview = "Safe Preview"

    var allowsTextSelection: Bool { self == .original }
}

private struct PreviewTextSelection: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.textSelection(.enabled)
        } else {
            content.textSelection(.disabled)
        }
    }
}
