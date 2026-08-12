import AppKit
import ApplicationServices

/// Remembers the last foreground app that isn’t Qopy, so menu-bar actions
/// can still read that app’s selection after focus moves.
@MainActor
final class FrontAppTracker {
    static let shared = FrontAppTracker()

    private(set) var previousApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    func start() {
        guard observer == nil else { return }
        let workspace = NSWorkspace.shared
        if let front = workspace.frontmostApplication, !Self.isSelf(front) {
            previousApp = front
        }
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                guard !Self.isSelf(app) else { return }
                self?.previousApp = app
            }
        }
    }

    private static func isSelf(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == Bundle.main.bundleIdentifier
            || app.processIdentifier == ProcessInfo.processInfo.processIdentifier
    }
}

enum SelectionCapture {
    @MainActor
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Reads selected text from the previously focused app via Accessibility,
    /// then falls back to a targeted ⌘C against that app if needed.
    @MainActor
    static func selectedText() -> String? {
        let trusted = ensureAccessibility(prompt: true)
        let target = targetApplication()

        if trusted, let text = axSelectedText(in: target) {
            return text
        }

        if let text = copySelectionViaClipboard(in: target) {
            return text
        }

        return nil
    }

    @MainActor
    static func clipboardText() -> String? {
        let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, !text.isEmpty else { return nil }
        return text
    }

    @MainActor
    static func writeToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    private static func targetApplication() -> NSRunningApplication? {
        if let previous = FrontAppTracker.shared.previousApp,
           previous.isTerminated == false,
           previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return previous
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            return front
        }
        return nil
    }

    private static func axSelectedText(in app: NSRunningApplication?) -> String? {
        if let app, let text = axSelectedText(pid: app.processIdentifier) {
            return text
        }

        // System-wide focused element (works when the source app still holds AX focus).
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObject: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        ) == .success,
              let focused = focusedObject else { return nil }
        return selectedText(from: (focused as! AXUIElement))
    }

    private static func axSelectedText(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        var focusedObject: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        ) == .success,
           let focused = focusedObject,
           let text = selectedText(from: focused as! AXUIElement) {
            return text
        }

        // Some apps expose selection on the window rather than the focused leaf.
        var windowObject: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowObject
        ) == .success,
           let window = windowObject,
           let text = selectedText(from: window as! AXUIElement) {
            return text
        }

        return nil
    }

    private static func selectedText(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value
        ) == .success,
           let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    @MainActor
    private static func copySelectionViaClipboard(in app: NSRunningApplication?) -> String? {
        let pasteboard = NSPasteboard.general
        let savedChangeCount = pasteboard.changeCount
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
            let copy = NSPasteboardItem()
            var wrote = false
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                    wrote = true
                }
            }
            return wrote ? copy : nil
        }

        // Activate the source app so ⌘C hits the selection, not the menu bar.
        app?.activate(options: [.activateIgnoringOtherApps])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))

        pasteboard.clearContents()

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if pasteboard.changeCount != savedChangeCount { break }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        let copied = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        pasteboard.clearContents()
        if let savedItems, !savedItems.isEmpty {
            pasteboard.writeObjects(savedItems)
        }

        guard let copied, !copied.isEmpty else { return nil }
        return copied
    }
}
