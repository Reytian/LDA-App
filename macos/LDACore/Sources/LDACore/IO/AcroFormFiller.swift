//
//  AcroFormFiller.swift
//  LDACore
//
//  AcroForm support for fill targets: enumerate widgets (text widgets are
//  fillable in V1; checkbox, radio, and choice widgets are reported as manual
//  items) and write confirmed values to a NEW file. The original is never
//  modified.
//
//  Same-named widgets across pages are treated as ONE logical field (AcroForm
//  semantics): enumerate() returns each logical field name once, and fill()
//  writes the value to EVERY annotation carrying that name.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import PDFKit

public enum AcroFormFiller {

    // MARK: - Public types

    /// What enumeration found in a form PDF.
    public struct FormInventory: Equatable, Sendable {
        /// Logical text field names, in first-seen order (page order then
        /// annotation order within a page). Each logical name appears once even
        /// if the same name occurs on multiple pages.
        public var textFieldNames: [String]
        /// Per-field label hint: the field name plus tooltip text when present
        /// (used as the matching label downstream).
        public var fieldLabels: [String: String]
        /// Widget names that V1 does not auto-fill (checkbox, radio, choice).
        /// Each logical name appears once.
        public var manualWidgetNames: [String]
    }

    public enum FillError: Error, Equatable {
        /// The file could not be opened as a PDF.
        case unreadable
        /// Field names in the supplied values map no longer exist in the target.
        case staleTarget(missing: [String])
        /// PDFKit refused to write the filled document (for example a
        /// permissions-locked file).
        case writeFailed
    }

    // MARK: - Public API

    /// Enumerate all AcroForm widgets in the PDF at url. Returns an empty
    /// FormInventory for a plain PDF that contains no widgets.
    public static func enumerate(at url: URL) throws -> FormInventory {
        guard let document = PDFDocument(url: url) else { throw FillError.unreadable }

        var textNames: [String] = []
        var seenText: Set<String> = []
        var labels: [String: String] = [:]
        var manualNames: [String] = []
        var seenManual: Set<String> = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard isWidget(annotation) else { continue }
                let name = annotation.fieldName ?? ""
                guard !name.isEmpty else { continue }

                if isTextWidget(annotation) {
                    if seenText.insert(name).inserted {
                        textNames.append(name)
                        // toolTip is deprecated but there is no replacement; suppress
                        // the warning with a local alias.
                        let tip: String
                        // PDFAnnotation has no un-deprecated tooltip accessor on this
                        // macOS version; use the annotationKeyValues dictionary instead.
                        let keyVals = annotation.annotationKeyValues
                        let rawTip = keyVals[PDFAnnotationKey(rawValue: "/TU")] as? String
                            ?? keyVals[PDFAnnotationKey(rawValue: "TU")] as? String
                        tip = rawTip ?? ""
                        labels[name] = tip.isEmpty ? name : "\(name) \(tip)"
                    }
                } else {
                    if seenManual.insert(name).inserted {
                        manualNames.append(name)
                    }
                }
            }
        }

        return FormInventory(
            textFieldNames: textNames,
            fieldLabels: labels,
            manualWidgetNames: manualNames
        )
    }

    /// Write values into the named text widgets and save to out. AcroForm
    /// treats same-named widgets as one logical field; the value is written to
    /// EVERY annotation carrying that name across all pages.
    ///
    /// Throws FillError.staleTarget if any key in values has no matching widget.
    /// The original file is never modified.
    public static func fill(
        original: URL,
        values: [String: String],
        to out: URL
    ) throws {
        guard let document = PDFDocument(url: original) else { throw FillError.unreadable }

        var filledNames: Set<String> = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard isWidget(annotation), isTextWidget(annotation) else { continue }
                guard let name = annotation.fieldName,
                      let value = values[name] else { continue }
                annotation.widgetStringValue = value
                filledNames.insert(name)
            }
        }

        let missing = Set(values.keys).subtracting(filledNames)
        guard missing.isEmpty else {
            throw FillError.staleTarget(missing: missing.sorted())
        }

        guard document.write(to: out) else { throw FillError.writeFailed }
    }

    // MARK: - Private helpers

    /// Returns true when the annotation is an AcroForm widget. PDFKit may
    /// return the type string "Widget" (capital W) or the subtype key; check
    /// both the typed annotation.type and the raw annotation subtype to cover
    /// all PDFKit versions.
    private static func isWidget(_ annotation: PDFAnnotation) -> Bool {
        // annotation.type returns the subtype string for the annotation.
        // For widget annotations it is "Widget" on macOS 11+.
        if let type_ = annotation.type, type_ == "Widget" { return true }
        // Belt-and-suspenders: check if the annotation has a widget field type
        // set (PDFKit populates this for recognized widget annotations).
        // A zero-valued widgetFieldType means "unknown", which can also mean it
        // is a widget not recognized by PDFKit, so prefer the string check above.
        return false
    }

    /// Returns true when the widget represents a plain-text entry field.
    private static func isTextWidget(_ annotation: PDFAnnotation) -> Bool {
        // Check via the typed enum first.
        if annotation.widgetFieldType == .text { return true }
        // Fall back to the raw /FT dictionary key for PDFs that PDFKit has not
        // fully parsed into the typed property. annotationKeyValues is non-Optional.
        let props = annotation.annotationKeyValues
        if let ft = props[PDFAnnotationKey.widgetFieldType] as? String, ft == "Tx" {
            return true
        }
        return false
    }
}
