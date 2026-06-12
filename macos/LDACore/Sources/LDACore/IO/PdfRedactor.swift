//
//  PdfRedactor.swift
//  LDACore
//
//  Produces a SAFE redacted-review PDF by destroying, not merely covering, the
//  PII under each RedactionBox. The PDF is never the edit surface; restore
//  happens on the generated companion. This output exists so a human can eyeball
//  where PII was detected and is also safe to share.
//
//  Rendering strategy on macOS (no UIGraphics): each source page is rasterized
//  into an offscreen bitmap, the page content AND the opaque redaction boxes
//  (plus token labels) are drawn into that bitmap, and the output page content is
//  ONLY the resulting flattened image. The source page content stream is never
//  drawn into the output PDF, so the original text glyphs and any embedded image
//  XObjects (signatures, stamps) are gone. The covered regions therefore cannot
//  be recovered via PDFKit .string, findString, pdftotext, copy/paste, or by
//  pulling the source Image XObject back out.
//
//  Trade-off: the redacted pages are image-only (no selectable text). For a
//  privacy tool that is the intended, safe behavior: content removal beats
//  preserving a selectable text layer that would leak the PII.
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

/// Render scale (DPI factor) used to rasterize each page. 200 dpi over the 72
/// pt/in PDF user space keeps redacted pages legible without bloating the file.
private let renderScale: CGFloat = 200.0 / 72.0

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

            // The output page is emitted in DISPLAY orientation (origin zero,
            // size swapped for /Rotate 90/270) with no rotation flag of its
            // own, so the redacted review PDF always reads upright.
            var pageBox = CGRect(
                origin: .zero,
                size: PdfPageGeometry.displaySize(of: page)
            )
            context.beginPage(mediaBox: &pageBox)

            // Flatten the page content and the redaction boxes into a single
            // raster, then emit ONLY that raster as the page content. Because the
            // source page is never drawn into the output PDF, the original glyphs
            // and embedded image XObjects do not survive under the boxes.
            if let flattened = renderFlattenedPage(
                page,
                displayBox: pageBox,
                boxes: boxesByPage[index] ?? []
            ) {
                context.draw(flattened, in: pageBox)
            } else {
                // Rasterization failed (for example a degenerate media box). Fall
                // back to painting only the opaque boxes onto a blank page so no
                // source content is ever copied through. This never leaks PII; in
                // the worst case the page is blank where the raster would be.
                context.saveGState()
                context.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
                context.fill(pageBox)
                context.restoreGState()
                let toDisplay = PdfPageGeometry.contentToDisplay(of: page)
                for box in boxesByPage[index] ?? [] {
                    drawOpaqueBox(displayRect(of: box, using: toDisplay), token: box.token, in: context)
                }
            }

            context.endPage()
        }

        context.closePDF()
    }

    /// Rasterizes one page into a bitmap in upright DISPLAY orientation, paints
    /// the page content and the opaque redaction boxes (with token labels) into
    /// that bitmap, and returns the flattened CGImage.
    ///
    /// Box rects arrive in RAW content space (the space both
    /// PDFSelection.bounds(for:) and the OCR box mapper report), and are
    /// transformed into display space before painting, so they land exactly
    /// over the glyphs they cover even on /Rotate 90/180/270 pages. The page
    /// content goes into pixels only; it never reaches the output PDF, so the
    /// covered text and image XObjects cannot be extracted from the result.
    private static func renderFlattenedPage(
        _ page: PDFPage,
        displayBox: CGRect,
        boxes: [RedactionBox]
    ) -> CGImage? {
        let pixelWidth = Int((displayBox.width * renderScale).rounded())
        let pixelHeight = Int((displayBox.height * renderScale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmap = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // White background so transparent PDFs flatten cleanly.
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Map display space into the bitmap, then draw the content upright
        // through the page's rotation transform (pixels only).
        bitmap.scaleBy(x: renderScale, y: renderScale)
        PdfPageGeometry.drawContentUpright(page, in: bitmap)

        // Paint the opaque boxes and labels ON the same bitmap, over the
        // content, after mapping each rect into display space. Labels stay
        // upright because the context CTM holds only the raster scale here.
        let toDisplay = PdfPageGeometry.contentToDisplay(of: page)
        for box in boxes {
            drawOpaqueBox(displayRect(of: box, using: toDisplay), token: box.token, in: bitmap)
        }

        return bitmap.makeImage()
    }

    /// Maps a content-space redaction rect into display space. Axis-aligned
    /// rects stay axis-aligned because the transform rotates by a multiple of
    /// 90 degrees.
    private static func displayRect(
        of box: RedactionBox,
        using toDisplay: CGAffineTransform
    ) -> CGRect {
        box.rect.applying(toDisplay).standardized
    }

    /// Draws one opaque box plus a small token label inside it.
    private static func drawOpaqueBox(_ rect: CGRect, token: String, in context: CGContext) {
        if rect.isNull || rect.isEmpty {
            return
        }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        guard let fillColor = CGColor(colorSpace: space, components: boxFillColorComponents) else { return }

        context.saveGState()
        context.setFillColor(fillColor)
        context.fill(rect)
        context.restoreGState()

        drawTokenLabel(token, in: rect, context: context)
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
