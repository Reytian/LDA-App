//
//  RestoreSourceGuard.swift
//  LDAUI
//
//  What the Restore preview showed must be what the approval writes.
//
//  THE FAILURE THIS FILE EXISTS TO PREVENT (R8). The preview reads the edited
//  redacted file, computes the restored text and shows it. The save panel
//  comes afterwards, deliberately, so the reader has already seen what they
//  are saving before they choose where to put it. That leaves a window, as
//  wide as the reader's attention, in which the file can change: the AI tool
//  that produced it writes again, a sync agent lands a newer copy, the reader
//  edits it in another window. The writer used to reread the URL without ever
//  asking whether it was still the file the preview described, so a document
//  the reader never saw was written under their approval, silently.
//
//  So the file is fingerprinted when the preview is computed, and the
//  fingerprint is checked immediately before the write. Immediately, and not
//  at approval: the save panel is modal and can be on screen for minutes, and
//  a check taken before it would leave the same window open at the end.
//
//  The refusal writes NOTHING. There is no partial answer to give here: the
//  restored text is a function of the whole source, so a changed source means
//  a different document, not a slightly different one. The remedy is to
//  preview it again, which the sentence says.
//
//  SourceFingerprint is reused rather than reimplemented: it already streams
//  SHA-256 through a FileHandle, which is also what keeps Data(contentsOf:)
//  out of the app for NetworkChokepointTests.
//
//  House rules: user-facing copy is localized. No em-dash or
//  en-dash-as-separator.
//

import Foundation
import LDACore

/// Thrown by the approval step when the edited redacted file is no longer the
/// file the preview was computed from.
///
/// Its description is the sentence the sheet renders, so the outcome the
/// reader sees and the wording of the remedy cannot drift apart.
public struct RestoreSourceChangedError: LocalizedError, Equatable {
    public init() {}
    public var errorDescription: String? {
        RestorePreviewPresentation.sourceChangedRefusal()
    }
}

/// The one check between an approved preview and the file the writer reads.
enum RestoreSourceGuard {

    /// Throw RestoreSourceChangedError unless `file` still matches the
    /// fingerprint taken when its preview was computed.
    ///
    /// A file that can no longer be read at all is refused on the same
    /// sentence rather than passed through. It is certainly not the file the
    /// preview described, and naming the remedy is more use to the reader
    /// than the read error the writer would hit moments later.
    static func requireUnchanged(
        _ file: URL,
        matches previewed: SourceFingerprint
    ) throws {
        let current: SourceFingerprint
        do {
            current = try SourceFingerprint.of(file)
        } catch {
            throw RestoreSourceChangedError()
        }
        guard current == previewed else { throw RestoreSourceChangedError() }
    }
}
