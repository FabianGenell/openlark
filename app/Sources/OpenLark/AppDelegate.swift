import AppKit
import AVFoundation
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self(
        "toggleRecording",
        default: KeyboardShortcuts.Shortcut(.upArrow, modifiers: [.command])
    )
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayController: OverlayWindowController!
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private let recorder = AudioRecorder()
    private let sidecar = SidecarClient()
    private let vocab = VocabStore.shared
    private let history = HistoryStore.shared
    private let injector = TextInjector()
    private var recordingStartedAt: Date?
    private var localEscMonitor: Any?

    enum State { case idle, recording, transcribing }
    private var state: State = .idle

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLogger.log("app launched, pid=\(ProcessInfo.processInfo.processIdentifier)")

        // Auto-enable launch-at-login on first run. Once registered, this is a
        // no-op on subsequent launches. User can disable via the menu.
        let service = SMAppService.mainApp
        if service.status == .notRegistered {
            do {
                try service.register()
                AppLogger.log("launch-at-login auto-enabled (first run)")
            } catch {
                AppLogger.log("launch-at-login register failed: \(error)")
            }
        }
        AppLogger.log("launch-at-login status: \(service.status.rawValue)")

        // Trigger the mic permission prompt early so the first ⌘+↑ works cleanly
        // instead of failing silently with no input.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        AppLogger.log("mic permission at launch: status=\(micStatus.rawValue)")
        if micStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                AppLogger.log("mic permission granted=\(granted)")
            }
        }

        setupMenuBar()
        overlayController = OverlayWindowController()
        overlayController.audioLevelProvider = { [weak self] in
            self?.recorder.currentLevel ?? 0
        }

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            AppLogger.log("hotkey toggleRecording fired")
            self?.toggleRecording()
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "OpenLark"
            )
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Toggle Recording (⌘↑)",
            action: #selector(menuToggleRecording),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "History…",
            action: #selector(openHistory),
            keyEquivalent: "h"
        ))
        menu.addItem(NSMenuItem(
            title: "Vocabulary…",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit OpenLark",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem.menu = menu
    }

    @objc private func menuToggleRecording() {
        toggleRecording()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                sender.state = .off
                AppLogger.log("launch-at-login disabled")
            } else {
                try service.register()
                sender.state = .on
                AppLogger.log("launch-at-login enabled")
            }
        } catch {
            AppLogger.log("toggleLaunchAtLogin failed: \(error)")
            NSSound.beep()
        }
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func openHistory() {
        if let w = historyWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let window = HistoryWindowFactory.make(injector: injector)
        historyWindow = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.historyWindow = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettings() {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let window = SettingsWindowFactory.make()
        settingsWindow = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.settingsWindow = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Recording flow

    private func toggleRecording() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            // ignore double-tap while we're processing
            break
        }
    }

    private func startRecording() {
        AppLogger.log("startRecording")
        do {
            try recorder.start()
        } catch let err as AudioRecorder.RecorderError {
            NSSound.beep()
            AppLogger.log("recorder failed: \(err)")
            return
        } catch {
            NSSound.beep()
            AppLogger.log("recorder failed: \(error)")
            return
        }
        state = .recording
        recordingStartedAt = Date()
        overlayController.show()
        installEscMonitor()
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        removeEscMonitor()
        state = .transcribing
        overlayController.setProcessing()

        guard let wav = recorder.stopAndExportWAV() else {
            AppLogger.log("stopAndTranscribe: no audio captured")
            cancel()
            return
        }
        AppLogger.log("stopAndTranscribe: \(wav.count) bytes captured, sending to sidecar")

        Task.detached { [weak self] in
            guard let self else { return }
            let result = await self.sidecar.transcribe(wav: wav)
            await MainActor.run {
                self.overlayController.hide()
                switch result {
                case .success(let raw):
                    let corrected = self.vocab.correct(raw)
                    AppLogger.log("transcribed: \(raw.count) chars raw, \(corrected.count) chars corrected")
                    if !corrected.isEmpty {
                        let duration = self.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                        self.history.add(text: corrected, durationSeconds: duration)
                        self.injector.inject(text: corrected)
                    }
                case .failure(let err):
                    AppLogger.log("transcription failed: \(err)")
                    NSSound.beep()
                }
                self.recordingStartedAt = nil
                self.state = .idle
            }
        }
    }

    private func cancel() {
        removeEscMonitor()
        recorder.cancel()
        overlayController.hide()
        state = .idle
    }

    // MARK: - Esc monitor

    private func installEscMonitor() {
        // Use a CGEventTap so Esc cancels recording from any app while overlay is up,
        // without us having to register Esc as a global hotkey (which would
        // break Esc behaviour everywhere else).
        EscEventTap.shared.enable { @Sendable in
            DispatchQueue.main.async { [weak self] in self?.cancel() }
        }
    }

    private func removeEscMonitor() {
        EscEventTap.shared.disable()
    }
}
