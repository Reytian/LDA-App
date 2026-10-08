import Foundation

extension DocxImporter {
    /// Inspect the whole editable surface, including headers and notes. Import
    /// never accepts/rejects revisions implicitly: Word must resolve them first.
    public func unresolvedTrackedChangeCount(_ url: URL) throws -> Int {
        try ImportLimits.enforceDocumentSize(at: url)
        let budget = ArchiveBudget()
        var count = 0
        for path in [docxMainPartPath] + DocxParts.textBearingPartPaths(in: url) {
            let data = try DocxZip.readEntry(path, from: url, budget: budget)
            _ = try DocxDocumentXML.parse(data)
            let delegate = RevisionCounter()
            let parser = XMLParser(data: data)
            parser.shouldProcessNamespaces = true
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse() else { throw DocumentIOError.corrupt("Word revision metadata could not be read") }
            count += delegate.count
        }
        return count
    }
}

private final class RevisionCounter: NSObject, XMLParserDelegate {
    var count = 0
    private let namespaces: Set<String> = [
        "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
        "http://purl.oclc.org/ooxml/wordprocessingml/main"
    ]
    private let names: Set<String> = ["ins", "del", "moveFrom", "moveTo", "cellIns", "cellDel", "cellMerge",
        "numberingChange", "tblGridChange", "customXmlInsRangeStart", "customXmlDelRangeStart",
        "customXmlMoveFromRangeStart", "customXmlMoveToRangeStart", "moveFromRangeStart", "moveToRangeStart"]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if namespaces.contains(namespaceURI ?? ""), names.contains(name) || name.hasSuffix("PrChange") {
            count += 1
        }
    }
}
