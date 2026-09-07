//
//  DocxXML.swift
//  LDACore
//
//  Shared internal helpers for reading, parsing, and rewriting the
//  word/document.xml part of a .docx package. This module models the XML as an
//  ordered sequence of segments so that a redact pass can surgically rewrite the
//  text of individual w:t runs while preserving every other byte of the
//  original markup (formatting, run properties, namespaces, and so on).
//
//  Offset convention: the concatenated visible text built by DocxLayout uses
//  UTF-16 code-unit offsets, the same NSRange-compatible convention as Span in
//  CoreTypes.swift. start is inclusive, end is exclusive.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import ZIPFoundation

// MARK: - Document part path

/// The fixed path of the main document part inside a .docx package.
let docxMainPartPath = "word/document.xml"

// MARK: - Run model

/// A single text element (w:t, or w:delText inside a tracked deletion)
/// discovered in document.xml.
///
/// charStart and charLength are UTF-16 offsets into the concatenated visible
/// text produced by DocxLayout. textSegmentIndex points at the segment in the
/// parsed segment list whose payload is this run's editable text, so a redact
/// pass can rewrite exactly that segment.
struct DocxRun: Sendable {
    /// UTF-16 offset of this run's first character in the concatenated text.
    var charStart: Int
    /// UTF-16 length of this run's text in the concatenated text.
    var charLength: Int
    /// Index into DocxLayout.segments of the editable text segment for this run.
    var textSegmentIndex: Int
}

// MARK: - XML segment model

/// One piece of the document.xml stream. A document is reconstructed by
/// concatenating every segment's serialized form in order.
///
/// - markup: raw XML that is copied through verbatim (tags, attributes,
///   whitespace, anything that is not editable run text).
/// - runText: the decoded text content of a single w:t or w:delText element.
///   This is the only segment kind a redact pass rewrites. On serialization it
///   is XML-escaped.
enum DocxSegment: Sendable {
    case markup(String)
    case runText(String)
}

// MARK: - Layout

/// The parsed layout of a document.xml part: the ordered segment list plus the
/// run map that ties concatenated-text offsets back to editable segments.
struct DocxLayout: Sendable {
    /// The ordered segments that reconstruct document.xml.
    var segments: [DocxSegment]
    /// The runs in document order, with UTF-16 offsets into the concatenated text.
    var runs: [DocxRun]
    /// The concatenated visible text: w:t contents in order, "\n" between
    /// paragraphs, "\n" for a w:br or w:cr, and "\t" for a w:tab. The break
    /// characters belong to no run (see DocxRun), so a replacement may never
    /// straddle one; SpanSplitter splits detected spans at them.
    var text: String
    /// How many tracked-change containers (w:ins, w:del, w:moveFrom, w:moveTo)
    /// the part carries. Deleted text parses inline with no boundary marker, so
    /// a span may straddle live and tracked runs and restore flattened into the
    /// first run; callers warn the user to accept all changes before redacting
    /// when this is non-zero.
    var trackedChangeCount: Int = 0
}

// MARK: - Zip helpers

enum DocxZip {
    /// Read a single entry's bytes from a zip archive at url.
    static func readEntry(_ path: String, from url: URL) throws -> Data {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw DocumentIOError.corrupt("cannot open zip at \(url.lastPathComponent)")
        }
        guard let entry = archive[path] else {
            throw DocumentIOError.corrupt("missing \(path)")
        }
        var collected = Data()
        do {
            _ = try archive.extract(entry) { chunk in
                collected.append(chunk)
            }
        } catch {
            throw DocumentIOError.corrupt("cannot extract \(path)")
        }
        return collected
    }

    /// Write a brand new zip archive at out from an ordered list of
    /// (path, bytes) parts. out is overwritten if it already exists. This is the
    /// minimal writer used to assemble a .docx package; it lives here so all
    /// ZIPFoundation usage stays inside the library target.
    static func writeArchive(parts: [(String, Data)], to out: URL) throws {
        if FileManager.default.fileExists(atPath: out.path) {
            try? FileManager.default.removeItem(at: out)
        }
        let writer: Archive
        do {
            writer = try Archive(url: out, accessMode: .create)
        } catch {
            throw DocumentIOError.unreadable("cannot create zip at \(out.lastPathComponent)")
        }
        for (path, data) in parts {
            do {
                try writer.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .deflate,
                    provider: { position, size in
                        let start = Int(position)
                        let end = min(start + size, data.count)
                        guard start < end else { return Data() }
                        return data.subdata(in: start ..< end)
                    }
                )
            } catch {
                throw DocumentIOError.unreadable("cannot write \(path)")
            }
        }
    }

    /// Copy every entry from source into a brand new archive at out, but
    /// replace the bytes of replacements[path] when present and OMIT every
    /// path in removals. out is overwritten if it already exists. Entry order
    /// and per-entry metadata are reproduced as faithfully as ZIPFoundation
    /// allows.
    ///
    /// removals is how a member leaves the package: a copy-everything rewriter
    /// is exactly what let the custom XML data store keep the original value
    /// after the body was redacted (see DocxPackagePolicy). Callers that
    /// remove a member are responsible for the references to it.
    static func rewrite(
        source: URL,
        replacing replacements: [String: Data],
        removing removals: Set<String> = [],
        to out: URL
    ) throws {
        let reader: Archive
        do {
            reader = try Archive(url: source, accessMode: .read)
        } catch {
            throw DocumentIOError.corrupt("cannot open zip at \(source.lastPathComponent)")
        }

        if FileManager.default.fileExists(atPath: out.path) {
            try? FileManager.default.removeItem(at: out)
        }

        let writer: Archive
        do {
            writer = try Archive(url: out, accessMode: .create)
        } catch {
            throw DocumentIOError.unreadable("cannot create zip at \(out.lastPathComponent)")
        }

        for entry in reader {
            // Only files carry data; directories and symlinks are skipped because
            // a .docx never relies on explicit directory entries for validity.
            guard entry.type == .file else { continue }

            let path = entry.path
            if removals.contains(path) { continue }
            let data: Data
            if let replacement = replacements[path] {
                data = replacement
            } else {
                var collected = Data()
                do {
                    _ = try reader.extract(entry) { chunk in
                        collected.append(chunk)
                    }
                } catch {
                    throw DocumentIOError.corrupt("cannot extract \(path)")
                }
                data = collected
            }

            do {
                try writer.addEntry(
                    with: path,
                    type: .file,
                    uncompressedSize: Int64(data.count),
                    compressionMethod: .deflate,
                    provider: { position, size in
                        let start = Int(position)
                        let end = min(start + size, data.count)
                        guard start < end else { return Data() }
                        return data.subdata(in: start ..< end)
                    }
                )
            } catch {
                throw DocumentIOError.unreadable("cannot write \(path)")
            }
        }
    }
}

// MARK: - document.xml parsing

enum DocxDocumentXML {
    /// Parse document.xml bytes into a DocxLayout.
    ///
    /// The parser walks the raw XML once. It recognizes:
    /// - "<w:t ...>...</w:t>" and "<w:delText ...>...</w:delText>" elements:
    ///   their decoded text becomes a runText segment and a DocxRun entry. The
    ///   text of a tracked deletion is still in the file, so it is detected and
    ///   redacted exactly like visible text and restores into its own element.
    /// - "<w:p" paragraph starts: a "\n" is inserted into the concatenated text
    ///   BEFORE each paragraph except the first, so paragraph boundaries map to
    ///   newlines without trailing-newline noise.
    /// - "<w:tab/>", "<w:br/>", "<w:cr/>" as run children: one "\t" or "\n" in
    ///   the concatenated text, so text on either side is not glued together
    ///   (two tab-separated phone numbers must stay two numbers). Tab STOPS in
    ///   w:pPr/w:tabs are layout, not text, and contribute nothing.
    /// Everything else is preserved verbatim as markup segments.
    ///
    /// Throws DocumentIOError.corrupt on malformed input.
    static func parse(_ data: Data) throws -> DocxLayout {
        guard let xml = String(data: data, encoding: .utf8) else {
            throw DocumentIOError.corrupt("document.xml is not valid UTF-8")
        }

        let scalars = Array(xml)
        var segments: [DocxSegment] = []
        var runs: [DocxRun] = []
        var concatenated = ""
        var utf16Cursor = 0
        var sawParagraph = false
        // Open w:r elements, so break elements count as text only inside a run.
        var runDepth = 0
        // Inside w:pPr/w:tabs, whose w:tab children are tab stops, not text.
        var insideTabStops = false
        var trackedChangeCount = 0

        // Accumulator for verbatim markup between meaningful elements.
        var markupBuffer = ""

        func flushMarkup() {
            if !markupBuffer.isEmpty {
                segments.append(.markup(markupBuffer))
                markupBuffer = ""
            }
        }

        var i = 0
        let n = scalars.count

        while i < n {
            let c = scalars[i]
            if c != "<" {
                markupBuffer.append(c)
                i += 1
                continue
            }

            // We are at a "<". Read the tag name to decide handling.
            let tagInfo = try readTagName(scalars, from: i)
            let name = tagInfo.name

            // Every element match below is on a LITERAL "w:" name, so a part
            // that binds the Word namespace to another prefix would parse as
            // empty text while keeping its markup. Refuse instead; see
            // DocxNamespaceGuard. Named start tags only: a comment or a CDATA
            // section declares nothing, and character data is not a tag.
            if !tagInfo.isClosing, !name.isEmpty {
                try DocxNamespaceGuard.enforceSupportedBindings(
                    scalars,
                    from: i,
                    to: tagInfo.tagEnd
                )
            }

            if !tagInfo.isClosing && DocxRunText.trackedChangeElementNames.contains(name) {
                trackedChangeCount += 1
            }

            if name == "w:p" && !tagInfo.isClosing {
                // Paragraph start. Insert a newline boundary before all but the
                // first paragraph so consecutive paragraphs are separated. The
                // newline exists in the concatenated TEXT only; the markup is
                // copied through unchanged, so a parse/serialize cycle leaves
                // document.xml byte-identical outside the rewritten run text.
                if sawParagraph {
                    concatenated.append("\n")
                    utf16Cursor += ("\n" as NSString).length
                }
                sawParagraph = true
                // Copy the paragraph tag itself verbatim.
                markupBuffer.append(contentsOf: scalars[i ..< tagInfo.tagEnd])
                i = tagInfo.tagEnd
                continue
            }

            if DocxRunText.textElementNames.contains(name) && !tagInfo.isClosing && !tagInfo.isSelfClosing {
                // A text element. Capture the open tag, the raw inner text up to
                // the matching close tag, and emit a runText segment plus a run
                // entry.
                let openTag = String(scalars[i ..< tagInfo.tagEnd])
                let closeTag = "</\(name)>"
                guard let close = findClose(scalars, openTagEnd: tagInfo.tagEnd, closeTag: closeTag) else {
                    throw DocumentIOError.corrupt("unterminated \(name) element")
                }
                let rawInner = String(scalars[tagInfo.tagEnd ..< close.contentEnd])
                let decoded = xmlDecode(rawInner)

                flushMarkup()
                segments.append(.markup(openTag))

                let runCharStart = utf16Cursor
                let runLength = (decoded as NSString).length
                let textSegmentIndex = segments.count
                segments.append(.runText(decoded))
                concatenated.append(decoded)
                utf16Cursor += runLength

                segments.append(.markup(closeTag))

                runs.append(
                    DocxRun(
                        charStart: runCharStart,
                        charLength: runLength,
                        textSegmentIndex: textSegmentIndex
                    )
                )

                i = close.closeTagEnd
                continue
            }

            if name == "w:r" {
                if tagInfo.isClosing {
                    runDepth = max(0, runDepth - 1)
                } else if !tagInfo.isSelfClosing {
                    runDepth += 1
                }
            } else if name == "w:tabs" {
                insideTabStops = !tagInfo.isClosing && !tagInfo.isSelfClosing
            } else if !tagInfo.isClosing, runDepth > 0, !insideTabStops,
                      let breakText = DocxRunText.breakText(forElement: name) {
                // A run-level tab or line break: one character of text that
                // belongs to no run. The element itself is copied through
                // verbatim below, so the layout re-serializes unchanged.
                concatenated.append(breakText)
                utf16Cursor += (breakText as NSString).length
            }

            // Any other tag (including self-closing or closing tags, comments,
            // processing instructions, CDATA, DOCTYPE) is copied verbatim.
            markupBuffer.append(contentsOf: scalars[i ..< tagInfo.tagEnd])
            i = tagInfo.tagEnd
        }

        flushMarkup()

        return DocxLayout(
            segments: segments,
            runs: runs,
            text: concatenated,
            trackedChangeCount: trackedChangeCount
        )
    }

    /// Serialize a layout back into document.xml bytes. Markup segments are
    /// emitted verbatim; runText segments are XML-escaped.
    static func serialize(_ layout: DocxLayout) -> Data {
        Data(serializeXML(layout).utf8)
    }

    /// The serialized part as a string, for callers that post-process the
    /// markup before writing it.
    static func serializeXML(_ layout: DocxLayout) -> String {
        var out = ""
        for segment in layout.segments {
            switch segment {
            case .markup(let raw):
                out += raw
            case .runText(let text):
                out += xmlEncode(text)
            }
        }
        return out
    }

    // MARK: - Tag scanning

    private struct TagInfo {
        var name: String
        var tagEnd: Int       // index just past the ">"
        var isClosing: Bool   // "</...>"
        var isSelfClosing: Bool
    }

    /// Read the tag starting at index `start` (which must point at "<").
    /// Returns the element name (without "<", "/", or trailing attributes) and
    /// the index just past the closing ">".
    private static func readTagName(_ scalars: [Character], from start: Int) throws -> TagInfo {
        let n = scalars.count
        var j = start + 1
        var isClosing = false

        // Comments, CDATA, processing instructions, DOCTYPE: scan to matching end
        // and treat as an unnamed verbatim tag.
        if j < n && scalars[j] == "!" {
            // Handle comment "<!-- -->" specially because it can contain ">".
            if matches(scalars, at: j, "!--") {
                guard let end = findSequence(scalars, from: j, "-->") else {
                    throw DocumentIOError.corrupt("unterminated comment")
                }
                return TagInfo(name: "", tagEnd: end, isClosing: false, isSelfClosing: false)
            }
            // CDATA section.
            if matches(scalars, at: j, "![CDATA[") {
                guard let end = findSequence(scalars, from: j, "]]>") else {
                    throw DocumentIOError.corrupt("unterminated CDATA")
                }
                return TagInfo(name: "", tagEnd: end, isClosing: false, isSelfClosing: false)
            }
            // DOCTYPE or other declaration: scan to next ">".
            guard let end = findChar(scalars, from: j, ">") else {
                throw DocumentIOError.corrupt("unterminated declaration")
            }
            return TagInfo(name: "", tagEnd: end + 1, isClosing: false, isSelfClosing: false)
        }

        if j < n && scalars[j] == "?" {
            guard let end = findSequence(scalars, from: j, "?>") else {
                throw DocumentIOError.corrupt("unterminated processing instruction")
            }
            return TagInfo(name: "", tagEnd: end, isClosing: false, isSelfClosing: false)
        }

        if j < n && scalars[j] == "/" {
            isClosing = true
            j += 1
        }

        // Read the element name: letters, digits, ":", "-", "_", ".".
        var name = ""
        while j < n {
            let c = scalars[j]
            if c.isLetter || c.isNumber || c == ":" || c == "-" || c == "_" || c == "." {
                name.append(c)
                j += 1
            } else {
                break
            }
        }

        // Scan to the closing ">", tracking quoted attribute values so a ">"
        // inside an attribute does not end the tag prematurely.
        var inQuote: Character? = nil
        var isSelfClosing = false
        while j < n {
            let c = scalars[j]
            if let q = inQuote {
                if c == q { inQuote = nil }
                j += 1
                continue
            }
            if c == "\"" || c == "'" {
                inQuote = c
                j += 1
                continue
            }
            if c == ">" {
                if j > start && scalars[j - 1] == "/" {
                    isSelfClosing = true
                }
                j += 1
                return TagInfo(
                    name: name,
                    tagEnd: j,
                    isClosing: isClosing,
                    isSelfClosing: isSelfClosing
                )
            }
            j += 1
        }

        throw DocumentIOError.corrupt("unterminated tag")
    }

    private struct CloseInfo {
        var contentEnd: Int   // index of "<" that begins the close tag
        var closeTagEnd: Int  // index just past the close tag ">"
    }

    /// Find the matching close tag starting from openTagEnd. The .docx schema
    /// does not nest w:t inside w:t, so a simple forward search is correct.
    private static func findClose(
        _ scalars: [Character],
        openTagEnd: Int,
        closeTag: String
    ) -> CloseInfo? {
        let pattern = Array(closeTag)
        let n = scalars.count
        var j = openTagEnd
        while j <= n - pattern.count {
            if matchesArray(scalars, at: j, pattern) {
                return CloseInfo(contentEnd: j, closeTagEnd: j + pattern.count)
            }
            j += 1
        }
        return nil
    }

    // MARK: - Small scanning utilities

    private static func matches(_ scalars: [Character], at index: Int, _ literal: String) -> Bool {
        matchesArray(scalars, at: index, Array(literal))
    }

    private static func matchesArray(_ scalars: [Character], at index: Int, _ pattern: [Character]) -> Bool {
        guard index + pattern.count <= scalars.count else { return false }
        for k in 0 ..< pattern.count where scalars[index + k] != pattern[k] {
            return false
        }
        return true
    }

    private static func findChar(_ scalars: [Character], from index: Int, _ target: Character) -> Int? {
        var j = index
        while j < scalars.count {
            if scalars[j] == target { return j }
            j += 1
        }
        return nil
    }

    /// Find the index just past the first occurrence of `literal` at or after index.
    private static func findSequence(_ scalars: [Character], from index: Int, _ literal: String) -> Int? {
        let pattern = Array(literal)
        let n = scalars.count
        var j = index
        while j <= n - pattern.count {
            if matchesArray(scalars, at: j, pattern) {
                return j + pattern.count
            }
            j += 1
        }
        return nil
    }
}

// MARK: - XML entity coding

/// Decode the five predefined XML entities. Numeric character references are
/// decoded too so extracted text is human-readable.
func xmlDecode(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var result = ""
    result.reserveCapacity(s.count)
    let chars = Array(s)
    var i = 0
    let n = chars.count
    while i < n {
        if chars[i] != "&" {
            result.append(chars[i])
            i += 1
            continue
        }
        // Find the terminating ";".
        var j = i + 1
        while j < n && chars[j] != ";" && j - i <= 12 {
            j += 1
        }
        guard j < n && chars[j] == ";" else {
            result.append("&")
            i += 1
            continue
        }
        let entity = String(chars[(i + 1) ..< j])
        switch entity {
        case "amp": result.append("&")
        case "lt": result.append("<")
        case "gt": result.append(">")
        case "quot": result.append("\"")
        case "apos": result.append("'")
        default:
            if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
               let code = UInt32(entity.dropFirst(2), radix: 16),
               let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            } else if entity.hasPrefix("#"),
                      let code = UInt32(entity.dropFirst()),
                      let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            } else {
                // Unknown entity: keep it literal so no information is lost.
                result.append("&")
                result.append(entity)
                result.append(";")
            }
        }
        i = j + 1
    }
    return result
}

/// Escape text for safe inclusion as XML character data. Only the characters
/// that must be escaped inside element content are touched.
func xmlEncode(_ s: String) -> String {
    var result = ""
    result.reserveCapacity(s.count)
    for c in s {
        switch c {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        default: result.append(c)
        }
    }
    return result
}
