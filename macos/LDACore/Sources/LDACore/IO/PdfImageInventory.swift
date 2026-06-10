//
//  PdfImageInventory.swift
//  LDACore
//
//  The gate for the image-PII channel: reports which pages of a PDF contain at
//  least one embedded raster image XObject. Pure CGPDF inspection, no rendering,
//  so pure-text PDFs pay almost nothing and keep the fast text-layer path.
//
//  Conservative on uncertainty: if a page's resource structure cannot be walked,
//  the page is reported as image-bearing so the caller OCRs it rather than risk
//  missing image PII.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//
import Foundation
import CoreGraphics

/// Reports pages that contain embedded raster image XObjects.
public enum PdfImageInventory {
    /// Zero-based indices of pages that contain at least one image XObject.
    public static func pagesWithImages(_ url: URL) -> [Int] {
        guard let doc = CGPDFDocument(url as CFURL) else { return [] }
        let total = doc.numberOfPages
        guard total > 0 else { return [] }
        var pages: [Int] = []
        for i in 1...total {  // CGPDF pages are 1-based
            guard let page = doc.page(at: i) else {
                pages.append(i - 1)  // unreadable page: be conservative
                continue
            }
            guard let dict = page.dictionary else {
                pages.append(i - 1)
                continue
            }
            if pageHasImage(dict) { pages.append(i - 1) }
        }
        return pages
    }

    private static func pageHasImage(_ pageDict: CGPDFDictionaryRef) -> Bool {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources),
              let resources else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
              let xobjects else { return false }

        var found = false
        withUnsafeMutablePointer(to: &found) { foundPtr in
            CGPDFDictionaryApplyFunction(xobjects, { (_, object, info) in
                let foundPtr = info!.assumingMemoryBound(to: Bool.self)
                if foundPtr.pointee { return }
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let streamDict = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(streamDict, "Subtype", &subtype), let subtype {
                    if String(cString: subtype) == "Image" { foundPtr.pointee = true }
                }
            }, foundPtr)
        }
        return found
    }
}
