import AppKit
import SwiftUI

/// Borderless clear panel — same shell cursed uses. All visible glass comes from
/// SwiftUI `glassEffect`, not from an AppKit vibrancy fill.
@MainActor
enum GlassChrome {
    @discardableResult
    static func makeWindow<Content: View>(
        rootView: Content,
        size: NSSize,
        onClose: (() -> Void)? = nil
    ) -> NSWindow {
        let window = GlassPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false
        window.hidesOnDeactivate = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()

        let dismiss: () -> Void = { [weak window] in
            window?.close()
        }

        let wrapped = GlassPanelRoot(dismiss: dismiss) { rootView }
        let hosting = NSHostingController(rootView: wrapped)
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = hosting.view

        let monitor = PanelDismissMonitor(window: window)
        monitor.start()

        objc_setAssociatedObject(
            window,
            &AssociatedKeys.hosting,
            hosting,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        objc_setAssociatedObject(
            window,
            &AssociatedKeys.monitor,
            monitor,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        objc_setAssociatedObject(
            window,
            &AssociatedKeys.onClose,
            onClose as Any,
            .OBJC_ASSOCIATION_COPY_NONATOMIC
        )

        return window
    }

    /// Outer padding so Liquid Glass shading / shadow isn’t clipped by the window bounds.
    /// `.regular` blooms farther than `.clear` — keep this generous.
    static let inset: CGFloat = 48

    static let sendCardSize = NSSize(width: 280, height: 320)
    static let receiveCardSize = NSSize(width: 300, height: 320)

    static var sendWindowSize: NSSize {
        NSSize(
            width: sendCardSize.width + inset * 2,
            height: sendCardSize.height + inset * 2
        )
    }

    static var receiveWindowSize: NSSize {
        NSSize(
            width: receiveCardSize.width + inset * 2,
            height: receiveCardSize.height + inset * 2
        )
    }
}

private enum AssociatedKeys {
    static var hosting: UInt8 = 0
    static var monitor: UInt8 = 1
    static var onClose: UInt8 = 2
}

final class GlassPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Esc or click outside → close. Survives nonactivating panels via event monitors.
@MainActor
final class PanelDismissMonitor: NSObject {
    private weak var window: NSWindow?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var ignoreClicksUntil: Date = .distantPast

    init(window: NSWindow) {
        self.window = window
        super.init()
    }

    func start() {
        // Ignore the click that opened us (menu / hotkey side effects).
        ignoreClicksUntil = Date().addingTimeInterval(0.25)

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // esc
            self?.dismiss()
            return nil
        }

        // Global Esc so it still works if focus stayed in another app.
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.dismiss() }
        }

        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleMouseDown(event)
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            Task { @MainActor in self?.handleMouseDown(event) }
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard Date() >= ignoreClicksUntil else { return }
        guard let window, window.isVisible else { return }

        // Clicks inside this panel should not dismiss.
        if event.window === window { return }

        if !window.frame.contains(NSEvent.mouseLocation) {
            dismiss()
        }
    }

    func dismiss() {
        window?.close()
    }

    func stop() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
    }
}

private struct GlassPanelRoot<Content: View>: View {
    var dismiss: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            content()

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.55))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .glassEffect(.clear.interactive(), in: .circle)
            .padding(.top, GlassChrome.inset + 10)
            .padding(.trailing, GlassChrome.inset + 10)
            .help("Close")
        }
        .background(Color.black.opacity(1.0 / 255.0))
        .onExitCommand(perform: dismiss)
    }
}
