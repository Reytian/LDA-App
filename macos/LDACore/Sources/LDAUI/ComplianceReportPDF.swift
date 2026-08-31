//
//  ComplianceReportPDF.swift
//  LDAUI
//
//  Minimal Markdown-to-PDF rendering for the exportable compliance report
//  (F6). One deliberately small mapping: heading lines become bold system
//  runs, every other line (tables included) renders as a monospaced block so
//  column alignment survives without a table layout engine. Paginated A4 via
//  CoreText; no dependencies beyond the system frameworks.
//
//  The renderer is content-agnostic on purpose: the report's wording and
//  claims discipline live in ComplianceReport (LDACore), and this file must
//  never add or reword a sentence.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import AppKit
import CoreText

enum ComplianceReportPDF {

    /// A4 page size in PDF points.
    private static let pageSize = CGSize(width: 595.2, height: 841.8)

    /// Page margin in points, generous enough for office printers.
    private static let pageMargin: CGFloat = 54

    /// Render the Markdown report as paginated A4 PDF data.
    static func render(markdown: String) -> Data {
        let attributed = attributedText(from: markdown)
        let data = NSMutableData()
        guard attributed.length > 0,
              let consumer = CGDataConsumer(data: data as CFMutableData) else {
            return Data()
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return Data()
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = mediaBox.insetBy(dx: pageMargin, dy: pageMargin)
        let path = CGPath(rect: textRect, transform: nil)

        var rendered = 0
        while rendered < attributed.length {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: rendered, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, context)
            context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            // Always advance by at least one character so a line that cannot
            // fit the frame can never loop the paginator forever.
            rendered = visible.location + max(visible.length, 1)
        }
        context.closePDF()
        return data as Data
    }

    /// The minimal Markdown-to-attributed mapping described in the header.
    /// Internal (not private) so tests can pin the heading and body styling.
    static func attributedText(from markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let suffix = index < lines.count - 1 ? "\n" : ""
            result.append(NSAttributedString(
                string: line + suffix,
                attributes: attributes(for: line)
            ))
        }
        return result
    }

    /// Attributes for one source line: heading levels map to bold system
    /// sizes; everything else is a monospaced body run.
    private static func attributes(for line: String) -> [NSAttributedString.Key: Any] {
        let font: NSFont
        let spacingBefore: CGFloat
        if line.hasPrefix("# ") {
            font = NSFont.boldSystemFont(ofSize: 17)
            spacingBefore = 0
        } else if line.hasPrefix("## ") {
            font = NSFont.boldSystemFont(ofSize: 13)
            spacingBefore = 10
        } else if line.hasPrefix("### ") {
            font = NSFont.boldSystemFont(ofSize: 11)
            spacingBefore = 6
        } else {
            font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
            spacingBefore = 0
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraph
        ]
    }
}
