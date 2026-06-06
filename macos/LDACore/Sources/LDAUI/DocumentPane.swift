//
//  DocumentPane.swift
//  LDAUI
//
//  The paper-forward document pane: the serif edit surface where the imported
//  text is shown with faint entity tint highlights and colored underlines, and
//  accepted entities render as sealed mono-token chips.
//
//  Rendering model:
//  - The full document text is shown as a serif body on the paper surface,
//    inside a vertically scrolling reading column capped at a comfortable
//    measure and centered with generous gutters.
//  - Each entity's span is visually marked by building one AttributedString from
//    the document text and applying, over each span's UTF-16 range, a faint tint
//    background plus a colored underline in the entity's Counsel hue.
//  - An ACCEPTED entity instead reads as a sealed token: a stronger background in
//    the entity hue at low opacity and a monospaced face, so it looks like a
//    filled chip carrying its mono token, for example [PERSON_1].
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
/// zone before any document is open.
public struct DocumentPane: View {
    @ObservedObject private var model: ReviewModel

    /// True while a draggable document hovers over the drop zone.
    @State private var isDropTargeted = false

    public init(model: ReviewModel) {
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
                Text("Drop a document to anonymize")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(CounselTheme.textPrimary)
                Text("PDF, Word (.docx), or plain text. Everything stays on this Mac.")
                    .font(.callout)
                    .foregroundStyle(CounselTheme.textSecondary)
            }
            .multilineTextAlignment(.center)

            Button {
                presentOpenPanel()
            } label: {
                Text("Choose File")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(CounselTheme.inkAccent)

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
            guard let url = urls.first else { return false }
            openURL(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: - Open

    /// Present a native open panel and open the chosen document.
    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.openContentTypes
        panel.message = "Choose a .txt, .docx, or .pdf document to anonymize."
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openURL(url)
    }

    /// Open a document URL (from a drop or the panel) on the review model.
    private func openURL(_ url: URL) {
        let needsScope = url.startAccessingSecurityScopedResource()
        Task {
            await model.open(url)
            if needsScope {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// The document types accepted for opening: plain text, Word, and PDF.
    private static let openContentTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .pdf]
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        return types
    }()

    // MARK: - Reading column

    /// The scrolling, width-capped serif reading column on the paper surface.
    private var readingColumn: some View {
        ScrollView(.vertical) {
            Text(attributedDocument)
                .font(.system(.body, design: .serif))
                .foregroundStyle(CounselTheme.textPrimary)
                .textSelection(.enabled)
                .lineSpacing(Layout.lineSpacing)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: Layout.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, Layout.gutter)
                .padding(.vertical, Layout.columnVerticalInset)
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

    /// The document text as an AttributedString with each entity span marked.
    private var attributedDocument: AttributedString {
        Self.makeAttributed(
            text: model.documentText,
            entities: model.entities
        )
    }

    /// Build the attributed document. Pure and side-effect free so it can be
    /// reasoned about and reused. Spans are applied back to front so the UTF-16
    /// to AttributedString index mapping computed against the original text
    /// stays valid for every span.
    static func makeAttributed(
        text: String,
        entities: [ReviewEntity]
    ) -> AttributedString {
        var attributed = AttributedString(text)

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
            attributed[range].backgroundColor = hue.opacity(Style.sealedFillOpacity)
            attributed[range].foregroundColor = hue.opacity(Style.sealedTextOpacity)
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
