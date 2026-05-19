import AppKit
import SwiftUI

@MainActor
final class OverlayWindowController {
    private static let frameDefaultsKey = "overlayWindowOrigin"

    private var window: NSPanel?
    private let model = OverlayModel()

    /// Called from main thread; sampled by the SwiftUI animation timer.
    var audioLevelProvider: (() -> Float)? {
        get { model.levelProvider }
        set { model.levelProvider = newValue }
    }

    func show() {
        model.isProcessing = false
        ensureWindow()
        guard let window else { return }
        positionWindow(window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1
        }
        model.start()
    }

    func setProcessing() {
        model.isProcessing = true
    }

    func hide() {
        model.stop()
        guard let window else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: { [weak window] in
            window?.orderOut(nil)
        })
    }

    private func ensureWindow() {
        if window != nil { return }
        // Window is intentionally larger than the visible pill so the SwiftUI
        // drop-shadow has room to render. macOS's own window shadow (hasShadow)
        // draws a rectangular shadow around the bounding box, ignoring the
        // rounded-corner mask — so we disable it and rely on the SwiftUI shadow.
        let panel = DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 144),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        // We handle dragging manually in DraggablePanel so we can restrict it
        // to the actual pill, not the shadow gutter.
        panel.isMovableByWindowBackground = false
        panel.pillInset = 20 // matches OverlayView's outer .padding
        panel.onDragEnded = { [weak self] in self?.persistFrame() }

        // Belt-and-braces: ensure the content view's backing layer is fully
        // transparent. Without this you can get a faint rectangular silhouette
        // around the pill where the NSHostingView's CALayer is opaque-black by
        // default.
        if let content = panel.contentView {
            content.wantsLayer = true
            content.layer?.backgroundColor = .clear
            content.layer?.isOpaque = false
        }

        let host = NSHostingView(rootView: OverlayView(model: model))
        host.frame = panel.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        host.layer?.isOpaque = false
        panel.contentView?.addSubview(host)
        self.window = panel
    }

    private func positionWindow(_ window: NSWindow) {
        if let saved = loadSavedOrigin(), pointIsOnVisibleScreen(saved, windowSize: window.frame.size) {
            window.setFrameOrigin(saved)
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = window.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 24
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func persistFrame() {
        guard let window else { return }
        let origin = window.frame.origin
        UserDefaults.standard.set(
            ["x": origin.x, "y": origin.y],
            forKey: Self.frameDefaultsKey
        )
    }

    private func loadSavedOrigin() -> NSPoint? {
        guard let dict = UserDefaults.standard.dictionary(forKey: Self.frameDefaultsKey),
              let x = dict["x"] as? CGFloat,
              let y = dict["y"] as? CGFloat else {
            return nil
        }
        return NSPoint(x: x, y: y)
    }

    private func pointIsOnVisibleScreen(_ origin: NSPoint, windowSize: NSSize) -> Bool {
        let rect = NSRect(origin: origin, size: windowSize)
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }
}

/// Borderless panel that drags only when the click lands on the visible pill,
/// not on the surrounding shadow gutter. The "pill" is the central region of
/// the content view, with `pillInset` points of empty/shadow padding around it.
final class DraggablePanel: NSPanel {
    var onDragEnded: (() -> Void)?
    var pillInset: CGFloat = 0

    override var canBecomeKey: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let content = contentView else { return }
        let local = content.convert(event.locationInWindow, from: nil)
        let pill = content.bounds.insetBy(dx: pillInset, dy: pillInset)
        guard pill.contains(local) else {
            // Click on the shadow gutter — ignore (don't drag, don't pass through).
            return
        }
        performDrag(with: event)
        onDragEnded?()
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var levels: [Float] = Array(repeating: 0, count: 64)
    @Published var isProcessing: Bool = false
    var levelProvider: (() -> Float)?

    private var timer: Timer?

    func start() {
        levels = Array(repeating: 0, count: levels.count)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let v = self.levelProvider?() ?? 0
            // shift left, append new sample
            var next = self.levels
            next.removeFirst()
            // amplify and clip — RMS is normally < 0.3, scale up so quiet speech still moves
            let amped = min(1.0, sqrt(max(0, v)) * 1.8)
            next.append(amped)
            self.levels = next
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
