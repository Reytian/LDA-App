//
//  SensitiveClipboard.swift
//  LDAUI
//
//  Writing to the system clipboard for content that must NOT linger there.
//
//  The problem: the companion's "Restore" puts DE-ANONYMIZED text on the
//  general pasteboard. Everything running on the Mac can read that pasteboard,
//  clipboard-history utilities archive it to their own storage, and Universal
//  Clipboard may forward it to the user's other devices. For a tool whose
//  promise is that client material stays on this Mac, leaving real names and
//  account numbers sitting in the pasteboard indefinitely is the weakest point
//  of the whole round trip.
//
//  Three mitigations, in descending order of how much they can be relied on:
//
//   1. Auto-clear. The write records the pasteboard's changeCount and clears it
//      after autoClearAfter seconds, but ONLY if the changeCount still matches.
//      That is what makes this safe to do at all: if the user copied anything
//      else in the meantime, their clipboard is left alone.
//   2. Concealed and transient markers. The two nspasteboard.org convention
//      types below are what clipboard managers read to decide not to archive an
//      item (the same convention password managers use). It is a CONVENTION
//      honored by well-behaved apps, not an OS-enforced guarantee, so it
//      reduces exposure rather than removing it.
//   3. Telling the user. The caller reports how long the value will stay
//      available, so pasting promptly is an informed choice rather than a
//      lucky one.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import AppKit
import Foundation

/// Clipboard writes for de-anonymized content.
@MainActor
enum SensitiveClipboard {

    /// How long restored values stay on the clipboard before being cleared.
    ///
    /// Long enough to switch apps and paste without hurrying, short enough that
    /// a forgotten clipboard is not an all-day exposure.
    static let autoClearAfter: TimeInterval = 30

    /// Marks the item as a secret, so clipboard managers skip archiving it.
    /// See https://nspasteboard.org.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Marks the item as short lived, a second signal to the same audience.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// Write text that must not linger.
    ///
    /// - Returns: the number of seconds until it is cleared, for the message
    ///   shown to the user.
    @discardableResult
    static func write(
        _ text: String,
        pasteboard: NSPasteboard = .general
    ) -> TimeInterval {
        pasteboard.clearContents()
        // Declare the convention markers alongside the real type. They must be
        // declared in the same declareTypes call as .string, or a manager that
        // reads the item sees only a plain string.
        pasteboard.declareTypes([.string, concealedType, transientType], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: concealedType)
        pasteboard.setString("", forType: transientType)

        scheduleClear(of: pasteboard, at: pasteboard.changeCount)
        return autoClearAfter
    }

    /// A one-line addition for the message shown after a sensitive write.
    static var expiryNote: String {
        "For safety it clears from the clipboard in \(Int(autoClearAfter)) seconds."
    }

    /// Clear the pasteboard after the delay.
    private static func scheduleClear(of pasteboard: NSPasteboard, at changeCount: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + autoClearAfter) {
            clearIfUnchanged(pasteboard, expectedChangeCount: changeCount)
        }
    }

    /// Clear the pasteboard only if nothing else has been copied since our
    /// write. Comparing changeCount is what keeps auto-clear from destroying
    /// something the user copied in the meantime, which would be a worse bug
    /// than the exposure it is preventing.
    ///
    /// Internal (not private) so the guard is unit-testable without waiting out
    /// the real delay.
    @discardableResult
    static func clearIfUnchanged(
        _ pasteboard: NSPasteboard,
        expectedChangeCount: Int
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        pasteboard.clearContents()
        return true
    }
}
