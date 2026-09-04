//
//  ScopedFileAccess.swift
//  LDAUI
//
//  A sandbox security scope with an EXPLICIT lifetime, for a flow whose work
//  no longer finishes inside the function that took the grant.
//
//  A URL that arrives by drag and drop carries a security-scoped grant that is
//  only valid between startAccessingSecurityScopedResource() and its stop
//  counterpart. The old Restore flow chose the output and wrote the file
//  inside the same call that took the grant, so releasing it in a `defer` on
//  the dropping function was correct by accident: the write had already
//  happened by the time the defer ran.
//
//  Putting a preview sheet in front of the write breaks that. The read of the
//  .docx parts and the write of the output now happen after the reader
//  approves, on a later run loop turn, so a `defer` in the dropping function
//  releases the grant BEFORE either one. The failure that produces is the
//  worst kind: it appears only under the App Sandbox, which neither XCTest nor
//  the unsandboxed SwiftPM dev binary exercises, so it ships green.
//
//  This holder makes the lifetime a decision rather than a side effect of
//  where the code happens to return. release() is idempotent, and deinit is
//  the backstop for a path that forgets.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import Foundation

/// One held security-scoped grant on a file, released exactly once.
///
/// A class, not a struct, deliberately: the grant is shared mutable state
/// owned by the operating system, and the holder has to be the same object
/// wherever it is passed so that release() cannot run twice on one grant.
final class ScopedFileAccess {

    /// The file the grant covers, kept for the release call.
    private let url: URL

    /// Whether this holder actually took a grant. A URL the process already
    /// has access to (anything chosen in an NSOpenPanel, or any path at all
    /// outside the sandbox) returns false from
    /// startAccessingSecurityScopedResource, and must NOT be released: the
    /// call is only balanced when the start succeeded.
    private var isHeld: Bool

    /// Take the grant. Cheap and safe to call for a URL that does not need
    /// one; `isHeld` records which case this was.
    init(_ url: URL) {
        self.url = url
        self.isHeld = url.startAccessingSecurityScopedResource()
    }

    /// Give the grant back. Idempotent, so the flow may call it on whichever
    /// path finishes first without checking whether another already did.
    func release() {
        guard isHeld else { return }
        isHeld = false
        url.stopAccessingSecurityScopedResource()
    }

    /// The backstop, not the plan. A flow that drops its last reference to a
    /// holder without releasing it still balances the grant, but the
    /// release point should be visible in the flow rather than left to
    /// whenever the last reference happens to go away.
    deinit {
        release()
    }
}
