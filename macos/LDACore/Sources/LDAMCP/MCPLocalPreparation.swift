import AppKit
import UniformTypeIdentifiers
import LDACore

/// File paths and added sensitive terms are collected locally and never become MCP arguments.
enum MCPLocalPreparation {
    struct Selection {
        let urls: [URL]
        let review: Bool
    }

    static func selectDocuments() throws -> Selection {
        guard Thread.isMainThread else { throw MCPVaultToolError.localPreparationCancelled }
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { throw MCPVaultToolError.localPreparationCancelled }
        #endif
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "LDA: Choose documents"
        panel.message = "Choose local documents for this request. Only redacted text can be shared with the connected AI."
        panel.prompt = "Prepare Documents"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ["docx", "txt", "md", "pdf", "png", "jpg", "jpeg"].compactMap { UTType(filenameExtension: $0) }
        let review = NSButton(checkboxWithTitle: "Review locally and add more PII before redaction", target: nil, action: nil)
        review.state = .off
        panel.accessoryView = review
        panel.isAccessoryViewDisclosed = true
        let outcome = run(panel: panel)
        guard outcome == .OK, !panel.urls.isEmpty, panel.urls.count <= 20 else {
            throw MCPVaultToolError.localPreparationCancelled
        }
        return Selection(urls: panel.urls, review: review.state == .on)
    }

    static func review(text: String, spans: [Span]) throws -> [CustomPattern] {
        guard Thread.isMainThread else { throw MCPVaultToolError.localPreparationCancelled }
        #if DEBUG
        if NSClassFromString("XCTestCase") != nil { throw MCPVaultToolError.localPreparationCancelled }
        #endif
        NSApplication.shared.activate(ignoringOtherApps: true)
        let controller = ReviewControls(text: text, spans: spans)
        let alert = NSAlert()
        alert.messageText = "LDA: Review protection"
        alert.informativeText = "Highlighted findings will be protected. Select missed text and choose Protect Selection, or enter a term found in a header or another part. Added terms are protected at every matching occurrence. This local review does not send the original to AI."
        alert.addButton(withTitle: "Continue with Redaction")
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = controller.view
        alert.window.animationBehavior = .none
        let timer = Timer(timeInterval: 600, repeats: false) { _ in NSApplication.shared.abortModal() }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let result = alert.runModal()
        timer.invalidate()
        alert.window.orderOut(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard result == .alertFirstButtonReturn else { throw MCPVaultToolError.localPreparationCancelled }
        return controller.patterns
    }

    private static func run(panel: NSOpenPanel) -> NSApplication.ModalResponse {
        panel.animationBehavior = .none
        let timer = Timer(timeInterval: 600, repeats: false) { _ in panel.cancel(nil) }
        RunLoop.main.add(timer, forMode: .modalPanel)
        let result = panel.runModal()
        timer.invalidate()
        panel.orderOut(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return result
    }

    private final class ReviewControls: NSObject {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        let textView = NSTextView()
        let term = NSTextField(frame: NSRect(x: 0, y: 36, width: 335, height: 26))
        let kind = NSPopUpButton(frame: NSRect(x: 345, y: 36, width: 140, height: 26))
        let status = NSTextField(labelWithString: "")
        let original: String
        let detected: [Span]
        var patterns: [CustomPattern] = []

        init(text: String, spans: [Span]) {
            original = text
            detected = spans
            super.init()
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 76, width: 720, height: 344))
            scroll.hasVerticalScroller = true
            textView.frame = scroll.bounds
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.font = .systemFont(ofSize: 14)
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            scroll.documentView = textView
            view.addSubview(scroll)
            term.placeholderString = "Additional term (optional)"
            term.setAccessibilityLabel("Additional term")
            kind.addItems(withTitles: EntityType.allCases.map(\.rawValue))
            kind.selectItem(withTitle: EntityType.person.rawValue)
            kind.setAccessibilityLabel("PII category")
            let protect = NSButton(title: "Protect Selection", target: self, action: #selector(add))
            protect.frame = NSRect(x: 495, y: 36, width: 225, height: 26)
            let undo = NSButton(title: "Undo Last Addition", target: self, action: #selector(removeLast))
            undo.frame = NSRect(x: 495, y: 0, width: 225, height: 26)
            status.frame = NSRect(x: 0, y: 0, width: 485, height: 26)
            [term, kind, protect, undo, status].forEach(view.addSubview)
            refresh()
        }

        @objc private func add() {
            let selection = textView.selectedRange()
            let typed = term.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = selection.length > 0 ? (original as NSString).substring(with: selection) : ""
            let value = typed.isEmpty ? selected.trimmingCharacters(in: .whitespacesAndNewlines) : typed
            guard !value.isEmpty, value.utf8.count <= 4096, patterns.count < 200,
                  !value.contains("\n"), !value.contains("\r") else {
                status.stringValue = "Select text within one paragraph, or enter a short term."
                return
            }
            let type = EntityType(rawValue: kind.titleOfSelectedItem ?? "") ?? .person
            let pattern = CustomPattern(text: value, type: type)
            if !patterns.contains(where: { $0.text == value && $0.type == type }) { patterns.append(pattern) }
            term.stringValue = ""
            refresh()
        }

        @objc private func removeLast() {
            if !patterns.isEmpty { patterns.removeLast() }
            refresh()
        }

        private func refresh() {
            let styled = NSMutableAttributedString(string: original, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.textColor])
            let spans = AdditionalProtection.merge(text: original, detected: detected, patterns: patterns)
            for span in spans where span.start >= 0 && span.end <= styled.length && span.end > span.start {
                styled.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.25), range: NSRange(location: span.start, length: span.end - span.start))
            }
            textView.textStorage?.setAttributedString(styled)
            status.stringValue = "\(detected.count) detected findings; \(patterns.count) additional terms."
        }
    }
}
