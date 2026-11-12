import AppKit
import LocalAuthentication

/// Consent happens on this Mac, never through an MCP parameter or a cached approval.
enum MCPLocalApproval {
    /// The count shown for an older artifact with no recorded exclusion status.
    static let unknownExclusionStatus = -1
    /// The count shown for an artifact redacted with patterns only although a
    /// detection model is configured.
    static let detectedWithoutModel = -2

    static func confirm(text: String, excludedCount: Int) -> Bool {
        guard Thread.isMainThread else { return false }
        #if DEBUG
        // Unit-test hosts must inject consent explicitly; never put a system prompt over XCTest.
        if NSClassFromString("XCTestCase") != nil { return false }
        #endif
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Share text with visible sensitive values?"
        let status: String
        switch excludedCount {
        case detectedWithoutModel:
            status = "This document was redacted with patterns only, although a detection model is set up, so people's names, company names and addresses were not looked for and may be in the text."
        case unknownExclusionStatus:
            status = "This older document has no recorded exclusion status."
        default:
            status = "\(excludedCount) detected occurrence(s) were left visible."
        }
        alert.informativeText = status + " The text below will be sent to the connected AI service. Allowing this applies to this response only."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Review and Authenticate")
        alert.buttons[0].keyEquivalent = "\u{1b}"
        alert.buttons[1].keyEquivalent = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 260))
        scroll.hasVerticalScroller = true
        let preview = NSTextView(frame: scroll.bounds)
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = .systemFont(ofSize: 13)
        preview.string = text
        preview.textContainer?.widthTracksTextView = true
        preview.autoresizingMask = [.width]
        scroll.documentView = preview
        alert.accessoryView = scroll
        // The stdio loop blocks between requests, so dismissal cannot depend on an animation.
        alert.window.animationBehavior = .none
        let deadline = Date().addingTimeInterval(90)
        let timer = Timer(timeInterval: 90, repeats: false) { _ in app.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let choice = alert.runModal()
        timer.invalidate()
        alert.window.orderOut(nil)
        // Flush deferred window removal before the main thread blocks on the next request.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard choice == .alertSecondButtonReturn, Date() < deadline else { return false }
        let decision = AuthenticationDecision()
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "approve sending the reviewed text with visible sensitive values to the connected AI service") { success, _ in
            decision.finish(success)
        }
        while decision.result == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        context.invalidate()
        return decision.result == true && Date() < deadline
    }

    private final class AuthenticationDecision: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        var result: Bool? { lock.withLock { value } }
        func finish(_ result: Bool) { lock.withLock { value = result } }
    }
}
