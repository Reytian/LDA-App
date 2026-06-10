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
        /// The output URL is the same path as the source; writing would
        /// overwrite the original.
        case outputEqualsInput
    }

    // MARK: - Public API

    /// Enumerate all AcroForm widgets in the PDF at url. Returns an empty
    /// FormInventory for a plain PDF that contains no widgets.
    ///
    /// Read-only text widgets (isReadOnly == true) are routed to
    /// manualWidgetNames, not textFieldNames, so the planner never proposes
    /// them for auto-fill.
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

                if isTextWidget(annotation) && !annotation.isReadOnly {
                    if seenText.insert(name).inserted {
                        textNames.append(name)
                        // PDFAnnotation has no un-deprecated tooltip accessor;
                        // read the /TU entry from the raw dictionary instead.
                        let keyVals = annotation.annotationKeyValues
                        let tip = keyVals[PDFAnnotationKey(rawValue: "/TU")] as? String ?? ""
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
    /// Read-only text widgets are never written. If a caller-supplied name
    /// targets a read-only widget (or a non-existent field), that name appears
    /// in the staleTarget missing list.
    ///
    /// Throws FillError.outputEqualsInput when out resolves to the same path as
    /// original, to prevent overwriting the source.
    /// Throws FillError.staleTarget if any key in values has no matching
    /// writable widget.
    /// The original file is never modified.
    public static func fill(
        original: URL,
        values: [String: String],
        to out: URL
    ) throws {
        guard out.standardized != original.standardized else {
            throw FillError.outputEqualsInput
        }

        guard let document = PDFDocument(url: original) else { throw FillError.unreadable }

        var filledNames: Set<String> = []

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            for annotation in page.annotations {
                guard isWidget(annotation), isTextWidget(annotation) else { continue }
                guard !annotation.isReadOnly else { continue }
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

    /// Returns true when the annotation is an AcroForm widget.
    /// annotation.type returns "Widget" (capital W) for widget annotations on
    /// macOS 11+.
    private static func isWidget(_ annotation: PDFAnnotation) -> Bool {
        guard let type_ = annotation.type else { return false }
        return type_ == "Widget"
    }

    /// Returns true when the widget represents a plain-text entry field.
    private static func isTextWidget(_ annotation: PDFAnnotation) -> Bool {
        return annotation.widgetFieldType == .text
    }
}
