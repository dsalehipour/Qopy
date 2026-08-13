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

    @MainActor
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
              let focused = element(from: focusedObject) else { return nil }
        return selectedText(from: focused)
    }

    @MainActor
    private static func axSelectedText(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)

        if let text = axSelectedText(inApp: appElement) {
            return text
        }

        // Chromium apps (Chrome, Brave, Edge, Electron) keep their web content out
        // of the accessibility tree until a client asks for it. This switch turns it
        // on; the tree takes a moment to build, so poll briefly for the selection.
        guard AXUIElementSetAttributeValue(
            appElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        ) == .success else { return nil }

        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if let text = axSelectedText(inApp: appElement) {
                return text
            }
        }

        return nil
    }

    private static func axSelectedText(inApp appElement: AXUIElement) -> String? {
        var focusedObject: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedObject
        ) == .success,
           let focused = element(from: focusedObject),
           let text = selectedText(from: focused) {
            return text
        }

        // Some apps expose selection on the window rather than the focused leaf.
        var windowObject: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &windowObject
        ) == .success,
           let window = element(from: windowObject),
           let text = selectedText(from: window) {
            return text
        }

        return nil
    }

    private static func element(from value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
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

        // A synthetic ⌘C merges with the modifiers physically held down, so firing
        // this straight off ⌃⌥⌘C would reach the app as ⌃⌥⌘C and copy nothing.
        waitForModifiersToClear()

        // Activate the source app so ⌘C hits the selection, not the menu bar.
        activate(app)

        pasteboard.clearContents()
        // clearContents() bumps the change count, so the baseline has to come after it.
        let baseline = pasteboard.changeCount

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true) // C
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if pasteboard.changeCount != baseline { break }
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

    /// Waits for the user to let go of a hotkey before synthetic keys are posted.
    @MainActor
    private static func waitForModifiersToClear(timeout: TimeInterval = 0.7) {
        let watched: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if NSEvent.modifierFlags.intersection(watched).isEmpty { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Brings the source app forward and waits for activation to actually land.
    @MainActor
    private static func activate(_ app: NSRunningApplication?) {
        guard let app, !app.isActive else { return }
        _ = app.activate()
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline, !app.isActive {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
