//
//  DocxNamespacePrefixTests.swift
//  LDACoreTests
//
//  Review finding 6 (2026-09-06): the document.xml parser matches the LITERAL
//  element names "w:t" and "w:delText" instead of resolving namespace
//  bindings. XML says the prefix is arbitrary: a package that binds the
//  WordprocessingML namespace to "x" and writes <x:t> is exactly as valid as
//  Word's own output, and Word opens it. Our parser saw no text at all, so
//  detection ran over an empty string, the redactor had nothing to replace,
//  and the markup, PII included, was copied into the "redacted" output.
//
//  Measured on the review's probe: importedText="" preservedPII=true. That is
//  the one outcome that must not survive. Namespace-aware matching through
//  parsing, scrubbing and rewriting is the larger fix; until then the import
//  REFUSES a representation it cannot read, which is honest and safe.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxNamespacePrefixTests: XCTestCase {

    private static let email = "client@example.test"
    private static let wml = DocxTestPackage.wordNamespace

    private func assertRefused(
        _ xml: String,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try DocxDocumentXML.parse(Data(xml.utf8)), message, file: file, line: line) { error in
            guard case DocumentIOError.unsupportedFormat(let detail) = error else {
                return XCTFail("expected an unsupported-representation refusal, got \(error)", file: file, line: line)
            }
            XCTAssertTrue(
                detail.lowercased().contains("namespace"),
                "the refusal must say what it could not read: \(detail)",
                file: file,
                line: line
            )
            XCTAssertFalse(
                detail.contains(Self.email),
                "a refusal must not quote the document's own content: \(detail)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - The silent empty extraction

    /// The review's probe: "x" bound to the Word namespace on the root.
    func testAnAlternatePrefixOnTheRootIsRefused() {
        let xml = "<x:document xmlns:x=\"\(Self.wml)\"><x:body><x:p><x:r>"
            + "<x:t>\(Self.email)</x:t></x:r></x:p></x:body></x:document>"
        assertRefused(xml, "an alternate prefix must not import as empty text")
    }

    /// The same namespace bound as the DEFAULT, so the elements carry no
    /// prefix at all and every literal "w:" match misses.
    func testADefaultNamespaceBindingIsRefused() {
        let xml = "<document xmlns=\"\(Self.wml)\"><body><p><r>"
            + "<t>\(Self.email)</t></r></p></body></document>"
        assertRefused(xml, "a default WordprocessingML binding must not import as empty text")
    }

    /// A nested rebinding on a single run. The document is 99 percent
    /// ordinary, so a root-only check would pass it and lose one run.
    func testANestedRebindingOnOneRunIsRefused() {
        let xml = "<w:document xmlns:w=\"\(Self.wml)\"><w:body>"
            + "<w:p><w:r><w:t>Ordinary text.</w:t></w:r></w:p>"
            + "<w:p><x:r xmlns:x=\"\(Self.wml)\"><x:t>\(Self.email)</x:t></x:r></w:p>"
            + "</w:body></w:document>"
        assertRefused(xml, "a per-run rebinding must not hide that run's text")
    }

    /// The mirror image: the prefix is "w" but it names some other
    /// vocabulary, so "w:t" is not Word text and treating it as text would
    /// rewrite a foreign element.
    func testTheWPrefixBoundToAnotherNamespaceIsRefused() {
        let xml = "<w:document xmlns:w=\"urn:example:not-word\"><w:body><w:p><w:r>"
            + "<w:t>\(Self.email)</w:t></w:r></w:p></w:body></w:document>"
        assertRefused(xml, "w bound elsewhere must not be read as Word text")
    }

    /// Single-quoted attributes are as valid as double-quoted ones, and
    /// LibreOffice and XML tooling emit them.
    func testASingleQuotedAlternateBindingIsRefused() {
        let xml = "<x:document xmlns:x='\(Self.wml)'><x:body><x:p><x:r>"
            + "<x:t>\(Self.email)</x:t></x:r></x:p></x:body></x:document>"
        assertRefused(xml, "quote style must not decide whether text is seen")
    }

    /// A whole package with an alternate prefix is refused at import, so no
    /// caller can reach detection with an empty string.
    func testAPackageWithAnAlternatePrefixIsRefusedAtImport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxNamespacePrefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("alternate-prefix.docx")
        let document = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
            + "<x:document xmlns:x=\"\(Self.wml)\"><x:body><x:p><x:r>"
            + "<x:t>\(Self.email)</x:t></x:r></x:p></x:body></x:document>"
        try DocxZip.writeArchive(
            parts: [
                ("[Content_Types].xml", Data("<Types/>".utf8)),
                ("word/document.xml", Data(document.utf8))
            ],
            to: url
        )

        XCTAssertThrowsError(try DocxImporter().importDocument(url)) { error in
            guard case DocumentIOError.unsupportedFormat = error else {
                return XCTFail("expected an unsupported-representation refusal, got \(error)")
            }
        }
    }

    // MARK: - What must still parse

    /// Word's own spelling, and the versioned Microsoft namespaces that share
    /// the "w" stem but are different vocabularies, all still parse.
    func testWordsOwnNamespacesStillParse() throws {
        let xml = "<w:document xmlns:w=\"\(Self.wml)\" "
            + "xmlns:r=\"\(DocxTestPackage.relationshipsNamespace)\" "
            + "xmlns:w14=\"http://schemas.microsoft.com/office/word/2010/wordml\" "
            + "xmlns:w15=\"\(DocxTestPackage.w15Namespace)\" "
            + "mc:Ignorable=\"w14 w15\"><w:body><w:p><w:r>"
            + "<w:t>\(Self.email)</w:t></w:r></w:p></w:body></w:document>"
        let layout = try DocxDocumentXML.parse(Data(xml.utf8))
        XCTAssertEqual(layout.text, Self.email)
    }

    /// A fragment with no declarations at all keeps parsing: the supplementary
    /// parts and the field-instruction fixtures are built that way.
    func testAFragmentWithoutDeclarationsStillParses() throws {
        let layout = try DocxDocumentXML.parse(Data("<w:p><w:r><w:t>Plain.</w:t></w:r></w:p>".utf8))
        XCTAssertEqual(layout.text, "Plain.")
    }

    /// A document whose visible TEXT happens to quote a namespace declaration
    /// is ordinary content, not a rebinding, and must still parse. The guard
    /// reads start tags, not character data.
    func testADeclarationQuotedInRunTextIsNotARebinding() throws {
        let quoted = xmlEncode("<x:t xmlns:x=\"\(Self.wml)\">")
        let xml = "<w:document xmlns:w=\"\(Self.wml)\"><w:body><w:p><w:r>"
            + "<w:t>\(quoted)</w:t></w:r></w:p></w:body></w:document>"
        let layout = try DocxDocumentXML.parse(Data(xml.utf8))
        XCTAssertEqual(layout.text, "<x:t xmlns:x=\"\(Self.wml)\">")
    }

    // MARK: - Representations that hide the same binding (review R2)

    /// The Unicode prefix used by the two R2 fixtures below, kept out of the
    /// string literals so the test source stays ASCII.
    private static let unicodePrefix = "\u{6587}"

    /// One character of the Word namespace URI written as a DECIMAL character
    /// reference, bound to "x". XML expands character references before an
    /// attribute value is a namespace name, so this IS the ordinary Word
    /// namespace bound to "x" and Word reads it as such. Comparing the raw
    /// attribute text let it through: the CLI exited 0, reported zero
    /// entities, and copied the address into the exported document XML.
    func testADecimalEncodedWordNamespaceIsRefused() {
        assertRefused(
            Self.alternatePrefixDocument(
                prefix: "x",
                namespace: "http://schemas.openxmlformats.org/wordprocessingml/2006/ma&#105;n"
            ),
            "a decimal character reference must not hide the Word namespace"
        )
    }

    /// The hexadecimal spelling of the same reference.
    func testAHexEncodedWordNamespaceIsRefused() {
        assertRefused(
            Self.alternatePrefixDocument(
                prefix: "x",
                namespace: "http://schemas.openxmlformats.org/wordprocessingml/2006/&#x6D;ain"
            ),
            "a hex character reference must not hide the Word namespace"
        )
    }

    /// A Unicode prefix bound to the ordinary Word namespace. An XML Name
    /// accepts letters far outside ASCII, so a prefix pattern of [A-Za-z_]
    /// never saw this declaration at all and the guard passed a part whose
    /// every element name it cannot match.
    func testAUnicodePrefixBoundToWordTextIsRefused() {
        assertRefused(
            Self.alternatePrefixDocument(prefix: Self.unicodePrefix, namespace: Self.wml),
            "a Unicode prefix must not hide a Word text binding"
        )
    }

    /// The reviewer's escaped-namespace package, refused at import so no
    /// caller can reach detection with an empty string.
    func testAPackageWithAnEncodedWordNamespaceIsRefusedAtImport() throws {
        try assertPackageRefused(
            Self.alternatePrefixDocument(
                prefix: "x",
                namespace: "http://schemas.openxmlformats.org/wordprocessingml/2006/ma&#105;n"
            ),
            named: "encoded-namespace.docx"
        )
    }

    /// The reviewer's Unicode-prefix package, refused at import.
    func testAPackageWithAUnicodePrefixIsRefusedAtImport() throws {
        try assertPackageRefused(
            Self.alternatePrefixDocument(prefix: Self.unicodePrefix, namespace: Self.wml),
            named: "unicode-prefix.docx"
        )
    }

    // MARK: - What decoding must not start refusing

    /// A Unicode prefix on a vocabulary this reader does not touch is
    /// ordinary, valid XML and must still parse. Refusing every non-ASCII
    /// prefix would be a different defect with the same cost to the lawyer.
    func testAUnicodePrefixOnAnUnrelatedNamespaceStillParses() throws {
        let xml = "<w:document xmlns:w=\"\(Self.wml)\" "
            + "xmlns:\(Self.unicodePrefix)=\"urn:example:notes\">"
            + "<w:body><w:p><w:r><w:t>\(Self.email)</w:t></w:r></w:p></w:body></w:document>"
        let layout = try DocxDocumentXML.parse(Data(xml.utf8))
        XCTAssertEqual(layout.text, Self.email)
    }

    /// An unrelated namespace whose URI carries a predefined entity decodes
    /// to something that is still not the Word namespace, so it parses. The
    /// decode step must not invent a binding.
    func testAnUnrelatedNamespaceWithAnEntityStillParses() throws {
        let xml = "<w:document xmlns:w=\"\(Self.wml)\" xmlns:q=\"urn:example:a&amp;b\">"
            + "<w:body><w:p><w:r><w:t>\(Self.email)</w:t></w:r></w:p></w:body></w:document>"
        let layout = try DocxDocumentXML.parse(Data(xml.utf8))
        XCTAssertEqual(layout.text, Self.email)
    }

    // MARK: - R2 fixtures

    /// A whole document whose every element carries `prefix`, bound to
    /// `namespace` on the root: the shape both R2 fixtures take.
    private static func alternatePrefixDocument(prefix: String, namespace: String) -> String {
        "<\(prefix):document xmlns:\(prefix)=\"\(namespace)\">"
            + "<\(prefix):body><\(prefix):p><\(prefix):r>"
            + "<\(prefix):t>\(email)</\(prefix):t>"
            + "</\(prefix):r></\(prefix):p></\(prefix):body></\(prefix):document>"
    }

    /// Write `document` as word/document.xml of a minimal package and assert
    /// the importer refuses it, so the refusal is proven at the edge a lawyer
    /// reaches and not only inside the parser.
    private func assertPackageRefused(_ document: String, named name: String) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxNamespacePrefix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent(name)
        let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        try DocxZip.writeArchive(
            parts: [
                ("[Content_Types].xml", Data("<Types/>".utf8)),
                ("word/document.xml", Data((declaration + document).utf8))
            ],
            to: url
        )

        XCTAssertThrowsError(try DocxImporter().importDocument(url)) { error in
            guard case DocumentIOError.unsupportedFormat = error else {
                return XCTFail("expected an unsupported-representation refusal, got \(error)")
            }
        }
    }
}
