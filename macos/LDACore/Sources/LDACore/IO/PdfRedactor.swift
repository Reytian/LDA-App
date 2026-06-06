//
//  PdfRedactor.swift
//  LDACore
//
//  Paints RedactionBox regions opaque to produce a visual-review PDF. The PDF is
//  never the edit surface; restore happens on the generated companion. This
//  output exists only so a human can eyeball where PII was detected.
//
//  Rendering strategy on macOS (no UIGraphics): each source page is drawn into a
//  fresh CGContext-backed PDF page, then opaque filled rectangles are drawn over
//  each box that belongs to that page. The underlying glyphs are fully covered by
//  the opaque fill, so the original text cannot be read from the box region.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import PDFKit
import CoreGraphics
import CoreText

/// Fill color (opaque black) used to cover detected PII glyphs.
private let boxFillColorComponents: [CGFloat] = [0.0, 0.0, 0.0, 1.0]

/// Token label color (white) drawn on top of the opaque box for orientation.
private let labelColorComponents: [CGFloat] = [1.0, 1.0, 1.0, 1.0]

/// Point size for the small monospace token label drawn inside each box.
private let labelFontSize: CGFloat = 7.0

/// Inset applied to the label so it sits just inside the box edge.
private let labelInset: CGFloat = 1.5

/// Renders a redacted copy of a PDF with opaque boxes painted over the supplied
/// regions.
public enum PdfRedactor {

    /// Draws opaque filled rectangles (and a small token label) over each box on
    /// the correct page, writing a new PDF to out.
    ///
    /// - Parameters:
    ///   - original: source PDF URL.
    ///   - boxes: redaction boxes in PDF/CoreGraphics page coordinates; pageIndex
    ///     is zero-based.
    ///   - out: destination URL for the redacted PDF.
    /// - Throws: DocumentIOError.corrupt when the source cannot be opened, or
    ///   DocumentIOError.unreadable when the output context cannot be created.
    public static func renderRedactedPDF(
        original: URL,
        boxes: [RedactionBox],
        to out: URL
    ) throws {
        guard let document = PDFDocument(url: original) else {
            throw DocumentIOError.corrupt("PDFKit could not open the source PDF at \(original.path)")
        }

        // Group boxes by page index once so per-page rendering is a simple lookup.
        var boxesByPage: [Int: [RedactionBox]] = [:]
        for box in boxes {
            boxesByPage[box.pageIndex, default: []].append(box)
        }

        // The mediaBox is supplied per page at beginPage time, so the context is
        // created with a nil default media box.
        guard let context = CGContext(out as CFURL, mediaBox: nil, nil) else {
            throw DocumentIOError.unreadable("Could not create a PDF graphics context at \(out.path)")
        }

        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }

            var mediaBox = page.bounds(for: .mediaBox)
            context.beginPage(mediaBox: &mediaBox)

            // Draw the original page content. PDFPage.draw(with: .mediaBox)
            // normalizes content into mediaBox-relative coordinates, which is the
            // same coordinate space PDFSelection.bounds(for:) reports box rects in.
            context.saveGState()
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            for box in boxesByPage[index] ?? [] {
                drawOpaqueBox(box, in: context)
            }

            context.endPage()
        }

        context.closePDF()
    }

    /// Draws one opaque box plus a small token label inside it.
    private static func drawOpaqueBox(_ box: RedactionBox, in context: CGContext) {
        let rect = box.rect
        if rect.isNull || rect.isEmpty {
            return
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        guard let fillColor = CGColor(colorSpace: space, components: boxFillColorComponents) else { return }

        context.saveGState()
        context.setFillColor(fillColor)
        context.fill(rect)
        context.restoreGState()

        drawTokenLabel(box.token, in: rect, context: context)
    }

    /// Draws the token in small monospace white text inside the box. Best-effort:
    /// if the label does not fit it is simply clipped by the box bounds.
    private static func drawTokenLabel(_ token: String, in rect: CGRect, context: CGContext) {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        guard let labelColor = CGColor(colorSpace: space, components: labelColorComponents) else { return }

        let font = CTFontCreateWithName("Menlo" as CFString, labelFontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: labelColor
        ]
        let attributed = NSAttributedString(string: token, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)

        context.saveGState()
        context.clip(to: rect)
        // Baseline a bit above the box bottom so the glyphs render inside.
        let baselineY = rect.minY + labelInset + labelFontSize * 0.15
        context.textPosition = CGPoint(x: rect.minX + labelInset, y: baselineY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
