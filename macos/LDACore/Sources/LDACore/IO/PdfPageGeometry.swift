//
//  PdfPageGeometry.swift
//  LDACore
//
//  Rotation-aware geometry for rasterizing PDF pages and for mapping rects
//  between a page's RAW CONTENT space and its upright DISPLAY space.
//
//  Scanner output routinely stores the raster sideways and stamps /Rotate 90
//  so viewers display it upright. Empirically (macOS 14/15):
//   - PDFPage.bounds(for:) returns the RAW box, not rotation-swapped.
//   - PDFPage.draw(with:to:) applies the rotation but into whatever canvas it
//     is given, so a raw-sized canvas clips the rotated content.
//   - PDFSelection.bounds(for:) reports RAW content-space rects even on
//     rotated pages.
//   - CGPDFPage.getDrawingTransform(_:rect:rotate:preserveAspectRatio:)
//     produces the exact content-to-display transform, with no scaling when
//     the destination rect equals the display size.
//
//  Convention: RedactionBox.rect and every rect handed to PDFPage.selection
//  live in RAW content space. Rasters for OCR and for the flattened redacted
//  output live in DISPLAY space (origin zero, swapped size for 90/270).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CoreGraphics
import PDFKit

/// Maps between a PDF page's raw content space and its upright display space.
enum PdfPageGeometry {

    /// The page's /Rotate entry normalized into {0, 90, 180, 270}.
    static func rotation(of page: PDFPage) -> Int {
        let raw = page.pageRef?.rotationAngle ?? Int32(page.rotation)
        return Int(((raw % 360) + 360) % 360)
    }

    /// The raw (unrotated) media box, preferring the CGPDFPage value because
    /// PDFKit can normalize bounds in version-dependent ways.
    static func rawMediaBox(of page: PDFPage) -> CGRect {
        page.pageRef?.getBoxRect(.mediaBox) ?? page.bounds(for: .mediaBox)
    }

    /// The size of the page as displayed: swapped for 90/270 rotations.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = rawMediaBox(of: page)
        let rot = rotation(of: page)
        if rot == 90 || rot == 270 {
            return CGSize(width: box.height, height: box.width)
        }
        return box.size
    }

    /// Transform mapping raw content coordinates into upright display
    /// coordinates (origin zero, size displaySize(of:)). Pure rotation plus
    /// translation; never scales, because the destination rect matches the
    /// display size exactly.
    static func contentToDisplay(of page: PDFPage) -> CGAffineTransform {
        if let cgPage = page.pageRef {
            return cgPage.getDrawingTransform(
                .mediaBox,
                rect: CGRect(origin: .zero, size: displaySize(of: page)),
                rotate: 0,
                preserveAspectRatio: true
            )
        }
        // No CGPDFPage (synthetic blank page): rotation is 0 by construction,
        // so only the origin shift remains.
        let box = rawMediaBox(of: page)
        return CGAffineTransform(translationX: -box.origin.x, y: -box.origin.y)
    }

    /// Draws the page's content upright into a context whose user space is the
    /// display space (origin zero, displaySize). The caller has already
    /// applied any raster scaling.
    static func drawContentUpright(_ page: PDFPage, in context: CGContext) {
        context.saveGState()
        if let cgPage = page.pageRef {
            context.concatenate(contentToDisplay(of: page))
            context.drawPDFPage(cgPage)
        } else {
            // Synthetic page without a pageRef: PDFKit drawing is the only
            // option; such pages carry no rotation.
            page.draw(with: .mediaBox, to: context)
        }
        context.restoreGState()
    }
}
