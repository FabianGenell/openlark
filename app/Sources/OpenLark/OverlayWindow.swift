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

    /// Whether the pill shows polish as armed, and what happens when the mic
    /// button in it is clicked.
    var polishOn: Bool {
        get { model.polishOn }
        set { model.polishOn = newValue }
    }

    var polishReady: Bool {
        get { model.polishReady }
        set { model.polishReady = newValue }
    }

    var onTogglePolish: (() -> Void)? {
        get { model.onTogglePolish }
        set { model.onTogglePolish = newValue }
    }

    var onSelectProfile: ((Int) -> Void)? {
        get { model.onSelectProfile }
        set { model.onSelectProfile = newValue }
    }

    func setProfiles(_ names: [String], active: String) {
        model.profileNames = names
        model.activeProfile = active
    }

    func show() {
        model.phase = .listening
        ensureWindow()
        guard let window else {
            AppLogger.log("overlay show: window nil after ensureWindow, fatal")
            return
        }
        // Re-assert level + collection behavior on each show. Some apps (Loom,
        // screen recorders) can demote our window when they grab the mic.
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        positionWindow(window)
        window.alphaValue = 0
        window.orderFrontRegardless()
        let screenInfo = NSScreen.main.map { "\($0.frame)" } ?? "nil"
        AppLogger.log("overlay show: frame=\(window.frame) mainScreen=\(screenInfo) visible=\(window.isVisible) onActiveSpace=\(window.isOnActiveSpace)")
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window.animator().alphaValue = 1
        }
        model.start()
    }

    func setTranscribing() {
        model.beginTranscribing()
    }

    func setPolishing() {
        model.beginPolishing()
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
        // rounded-corner mask, so we disable it and rely on the SwiftUI shadow.
        let panel = DraggablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 144),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // .screenSaver sits above fullscreen apps and the menu bar, so the
        // overlay is never hidden behind another window.
        panel.level = .screenSaver
        // .canJoinAllSpaces is enough to make the panel appear on every Space
        // the user switches to. .moveToActiveSpace + .stationary contradict it
        // and cause macOS to silently pick one, usually leaving the overlay
        // stranded on the Space where it was first shown.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .ignoresCycle,
            .fullScreenAuxiliary,
        ]
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
        model.hostWindow = { [weak panel] in panel }
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
        let size = window.frame.size
        if let saved = loadSavedOrigin(),
           let _ = screenFullyContaining(NSRect(origin: saved, size: size)) {
            window.setFrameOrigin(saved)
            return
        }
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
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

    /// Returns the screen whose `visibleFrame` fully contains the given rect,
    /// if any. Stricter than `intersects`. A saved origin from a now-disconnected
    /// display can technically intersect a remaining screen while being mostly
    /// off-screen, which is what caused the v0.2.0 "overlay never appears" bug.
    private func screenFullyContaining(_ rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.contains(rect) }
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
            // Click on the shadow gutter, ignore (don't drag, don't pass through).
            return
        }
        performDrag(with: event)
        onDragEnded?()
    }
}

@MainActor
final class OverlayModel: ObservableObject {
    enum Phase { case listening, transcribing, polishing }

    @Published var levels: [Float] = Array(repeating: 0, count: 64)
    @Published var phase: Phase = .listening
    /// Mirrors PolishSettings.polishByDefault for the recording on screen.
    @Published var polishOn: Bool = false
    /// False when polish is switched on but its model isn't on disk. The pill
    /// has to say so: claiming polish is armed and then pasting the raw
    /// transcript is the one thing it must never do.
    @Published var polishReady: Bool = true
    /// Profile names and which one is live, so the pill can switch profile
    /// mid-recording without the overlay knowing about the store.
    @Published var profileNames: [String] = []
    @Published var activeProfile: String = ""
    var levelProvider: (() -> Float)?
    var onTogglePolish: (() -> Void)?
    var onSelectProfile: ((Int) -> Void)?
    /// The panel the pill is drawn in, so a menu popped from it can duck under
    /// the panel's window level for as long as it's up.
    var hostWindow: (() -> NSWindow?)?

    var isProcessing: Bool { phase != .listening }

    private var timer: Timer?
    private var processingPhase: Double = 0

    func start() {
        phase = .listening
        levels = Array(repeating: 0, count: levels.count)
        startRecordingTimer()
    }

    /// Switch to the "Transcribing…" state. Stops sampling the (now-stale) mic
    /// level and replaces it with a synthetic scanning animation so the user
    /// can clearly see that we're processing, not still listening.
    func beginTranscribing() {
        phase = .transcribing
        processingPhase = 0
        startProcessingTimer()
    }

    /// Second processing step, only when polish is on. The animation carries
    /// straight on; only the label changes, so the overlay doesn't flicker
    /// between two stages of the same wait.
    func beginPolishing() {
        phase = .polishing
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func startRecordingTimer() {
        timer?.invalidate()
        // Timer callbacks fire on the main run loop, which is the main actor,
        // so assumeIsolated is safe here and avoids a Task hop per frame.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let v = self.levelProvider?() ?? 0
                var next = self.levels
                next.removeFirst()
                let amped = min(1.0, sqrt(max(0, v)) * 1.8)
                next.append(amped)
                self.levels = next
            }
        }
    }

    private func startProcessingTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.processingPhase += 0.14
                let count = self.levels.count
                var next = [Float](repeating: 0, count: count)
                // Two travelling sine waves crossed, a gentle "thinking" pulse.
                for i in 0..<count {
                    let pos = Double(i) / Double(max(1, count - 1))
                    let wave = sin(self.processingPhase + pos * .pi * 2.6)
                    let envelope = 0.5 + 0.5 * sin(self.processingPhase * 0.4)
                    let v = 0.20 + 0.18 * (wave + 1) / 2 * envelope
                    next[i] = Float(v)
                }
                self.levels = next
            }
        }
    }
}
