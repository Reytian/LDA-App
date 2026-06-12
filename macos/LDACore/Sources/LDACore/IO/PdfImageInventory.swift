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

    /// Maximum Form-XObject nesting depth walked before giving up and reporting
    /// the page as image-bearing. PDFs that nest this deep are pathological, so
    /// being conservative (OCR the page) is the safe choice.
    private static let maxFormDepth = 8

    private static func pageHasImage(_ pageDict: CGPDFDictionaryRef) -> Bool {
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(pageDict, "Resources", &resources),
              let resources else { return false }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
              let xobjects else { return false }
        return resourcesHaveImage(xobjects, depth: 0)
    }

    /// A collector for one CGPDFDictionaryApplyFunction pass. The C callback
    /// cannot capture Swift context, so it records its findings here via an
    /// opaque pointer.
    ///
    /// `found` is set when a direct Image XObject is seen. `forms` collects the
    /// nested Resources/XObject dictionaries of every Form XObject so the Swift
    /// recursion can descend into them after the apply completes. CGPDF pointers
    /// stay valid while the document is alive, so deferring the recursion is safe.
    private final class XObjectScan {
        var found = false
        var forms: [CGPDFDictionaryRef] = []
    }

    /// True when this XObject dictionary contains an Image XObject directly, or
    /// inside any nested Form XObject (recursively, with a depth guard).
    private static func resourcesHaveImage(_ xobjects: CGPDFDictionaryRef, depth: Int) -> Bool {
        // Too deep to walk safely: be conservative and report image-bearing.
        if depth > maxFormDepth { return true }

        let scan = XObjectScan()
        let info = Unmanaged.passUnretained(scan).toOpaque()
        CGPDFDictionaryApplyFunction(xobjects, { (_, object, info) in
            let scan = Unmanaged<XObjectScan>.fromOpaque(info!).takeUnretainedValue()
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let streamDict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                scan.found = true
            case "Form":
                // Descend into this Form's own Resources/XObject dictionary.
                var nestedResources: CGPDFDictionaryRef?
                guard CGPDFDictionaryGetDictionary(streamDict, "Resources", &nestedResources),
                      let nestedResources else { return }
                var nestedXObjects: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(nestedResources, "XObject", &nestedXObjects),
                   let nestedXObjects {
                    scan.forms.append(nestedXObjects)
                }
            default:
                break
            }
        }, info)

        if scan.found { return true }
        for nested in scan.forms where resourcesHaveImage(nested, depth: depth + 1) {
            return true
        }
        return false
    }
}
