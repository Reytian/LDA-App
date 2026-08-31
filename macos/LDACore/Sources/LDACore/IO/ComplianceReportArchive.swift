//
//  ComplianceReportArchive.swift
//  LDACore
//
//  The .ldareport container: one encrypted file holding both compliance
//  report deliverables (report.md and report.pdf).
//
//  WHY THE REPORT IS ENCRYPTED AT ALL. ComplianceReport is leak safe in the
//  sense that matters most for a mapping: it can never carry a protected
//  VALUE. It does, however, carry the client label and every document file
//  name, and in PRC legal practice those names are the parties. That is the
//  same reasoning SessionRecordStore gives for encrypting the record this
//  report is rendered from, and WorkspaceArchive gives for encrypting its
//  entry names. A report is the one artifact built to be handed to somebody
//  else, so writing it in the clear is where that reasoning would break.
//
//  FORMAT. Package first, then encrypt: one EncryptedContainer
//  (passphrase derivation only) whose decrypted payload is a small versioned
//  JSON document holding both deliverables. Unlike the workspace, the members
//  here are two fixed names, not document names, so there is nothing a zip
//  would buy: no member list to hide, no streaming to do, and two small
//  payloads. The JSON keeps the reader to one decode and one version probe.
//
//  Passphrase only, never the Keychain. A report exists to travel, so opening
//  one must need nothing but the file and the passphrase, exactly like the
//  workspace format.
//
//  The readable pair stays reachable through writeReadable, for a recipient
//  who has no copy of LDA. That is a deliberate, separate call: it is what
//  puts the party names on disk, so a caller has to ask for it by name.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation

// MARK: - Errors

/// Every way writing or opening an encrypted report file can fail, as cases a
/// caller can act on. A wrong passphrase and a damaged file must never be
/// reported as the same thing: one is fixed by typing again, the other is not.
public enum ComplianceReportArchiveError: Error, LocalizedError, Sendable, Equatable {

    /// The passphrase did not open the file (AES-GCM authentication failed).
    case wrongPassphrase

    /// The file declares a payload schema this build cannot read.
    case createdByNewerVersion(found: Int, supported: Int)

    /// The file is not a report file, is truncated, or its payload is not
    /// readable. The detail is safe to show: it never quotes content.
    case damagedFile(String)

    /// The finished file could not be written to the chosen location.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPassphrase:
            return "That passphrase did not open this report file."
        case .createdByNewerVersion(let found, let supported):
            return "This report file was created by a newer version of LDA "
                + "(format \(found); this app reads format \(supported)). "
                + "Update LDA to open it."
        case .damagedFile(let detail):
            return "This report file could not be read. \(detail)"
        case .writeFailed(let detail):
            return "The report file could not be saved. \(detail)"
        }
    }
}

// MARK: - Payload

/// The two deliverables one compliance report export carries.
public struct ComplianceReportBundle: Equatable, Sendable {

    /// The Markdown render, byte for byte as ComplianceReport produced it.
    public let markdown: String

    /// The paginated PDF twin of that same Markdown.
    public let pdf: Data

    public init(markdown: String, pdf: Data) {
        self.markdown = markdown
        self.pdf = pdf
    }
}

/// The stored shape inside the ciphertext.
private struct StoredComplianceReport: Codable {
    var formatVersion: Int
    var markdown: String
    var pdf: Data
}

/// Probes nothing but the schema version, so a file from a newer build is
/// reported as such instead of failing to decode a field it never had.
private struct ComplianceReportFormatProbe: Decodable {
    let formatVersion: Int
}

// MARK: - Archive

/// Reads and writes the encrypted compliance report file (.ldareport), and
/// writes the explicitly chosen readable pair.
public enum ComplianceReportArchive {

    // MARK: Format constants

    /// The payload schema version this build WRITES and the highest it reads.
    public static let currentFormatVersion = 1

    /// The file extension and its exported uniform type identifier. Both are
    /// declared in packaging/Info.plist; the constants live here so the app,
    /// the panels, and the packaging test agree on one spelling.
    public static let fileExtension = "ldareport"
    public static let uniformTypeIdentifier = "com.haotianyi.LDA.compliancereport"

    /// The written file names. Neutral by design: like the workspace's default
    /// name, none of them may carry the matter, because the outer file name
    /// sits outside the envelope and is the part most likely to be emailed.
    public static let encryptedFileName = "report." + fileExtension
    public static let markdownFileName = "report.md"
    public static let pdfFileName = "report.pdf"

    /// The encrypted envelope. Its magic is distinct from the workspace's
    /// ("LDAWRK") and the mapping sidecar's ("LDAMAP"), so feeding one reader
    /// the wrong file fails immediately with a format error rather than a
    /// confusing decryption failure. The Keychain service is required by the
    /// initializer but never reached: this container is only ever used with
    /// .passphrase protection.
    static let container = EncryptedContainer(
        magic: Array("LDARPT".utf8),
        keychainService: "ai.openclaw.lda.reportkey",
        containerDescription: "Report file"
    )

    // MARK: Writing

    /// Seal both deliverables into one encrypted file at `url`.
    ///
    /// The payload is assembled in memory, so no readable copy of the report
    /// ever touches the file system, and the only write is the finished
    /// ciphertext (atomic, by way of the container).
    public static func write(
        _ bundle: ComplianceReportBundle,
        to url: URL,
        passphrase: String
    ) throws {
        let stored = StoredComplianceReport(
            formatVersion: currentFormatVersion,
            markdown: bundle.markdown,
            pdf: bundle.pdf
        )
        let payload: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            payload = try encoder.encode(stored)
        } catch {
            throw ComplianceReportArchiveError.writeFailed(describe(error))
        }
        do {
            try container.save(payload, to: url, protection: .passphrase(passphrase))
        } catch {
            throw ComplianceReportArchiveError.writeFailed(describe(error))
        }
    }

    /// Write the readable pair (report.md and report.pdf) into a directory.
    ///
    /// This is the call that puts the client label and the document names on
    /// disk in the clear. It is deliberately separate from write(_:to:
    /// passphrase:) so no caller reaches it without meaning to.
    @discardableResult
    public static func writeReadable(
        _ bundle: ComplianceReportBundle,
        into directory: URL
    ) throws -> (markdown: URL, pdf: URL) {
        let markdownURL = directory.appendingPathComponent(markdownFileName)
        let pdfURL = directory.appendingPathComponent(pdfFileName)
        do {
            try Data(bundle.markdown.utf8).write(to: markdownURL, options: [.atomic])
            try bundle.pdf.write(to: pdfURL, options: [.atomic])
        } catch {
            throw ComplianceReportArchiveError.writeFailed(describe(error))
        }
        return (markdownURL, pdfURL)
    }

    // MARK: Reading

    /// Decrypt a report file and return both deliverables.
    ///
    /// Requires nothing but the file and the passphrase: no Keychain item, no
    /// app store, no prior knowledge of the matter.
    public static func read(from url: URL, passphrase: String) throws -> ComplianceReportBundle {
        let payload = try decryptPayload(at: url, passphrase: passphrase)
        try checkFormatVersion(of: payload)
        guard let stored = try? JSONDecoder().decode(StoredComplianceReport.self, from: payload) else {
            throw ComplianceReportArchiveError.damagedFile("Its payload could not be read.")
        }
        return ComplianceReportBundle(markdown: stored.markdown, pdf: stored.pdf)
    }

    /// Open the encrypted envelope, translating the container's generic
    /// failures into the report vocabulary.
    ///
    /// Note on the one distinction AES-GCM cannot make: a file truncated in
    /// its CIPHERTEXT fails authentication exactly as a wrong passphrase does,
    /// and is reported as .wrongPassphrase. Truncation that reaches the
    /// container header is caught structurally and reported as .damagedFile.
    private static func decryptPayload(at url: URL, passphrase: String) throws -> Data {
        do {
            return try container.load(from: url, protection: .passphrase(passphrase))
        } catch DocumentIOError.decryptionFailed {
            throw ComplianceReportArchiveError.wrongPassphrase
        } catch let error as DocumentIOError {
            throw ComplianceReportArchiveError.damagedFile(
                error.errorDescription ?? "The file could not be opened."
            )
        }
    }

    /// The version check runs before any other field is decoded, so a file
    /// written by a newer LDA says so instead of reading as damaged.
    private static func checkFormatVersion(of payload: Data) throws {
        guard let probe = try? JSONDecoder().decode(
            ComplianceReportFormatProbe.self,
            from: payload
        ) else {
            throw ComplianceReportArchiveError.damagedFile("It has no report payload.")
        }
        guard probe.formatVersion <= currentFormatVersion else {
            throw ComplianceReportArchiveError.createdByNewerVersion(
                found: probe.formatVersion,
                supported: currentFormatVersion
            )
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }
}
