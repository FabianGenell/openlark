import AppKit
@preconcurrency import AVFoundation
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
    private let settingsNavigator = SettingsNavigator()
    private var onboardingWindow: NSWindow?
    static let onboardingSeenKey = "onboardingSeen"
    private let recorder = AudioRecorder()
    private let sidecar = SidecarClient()
    private let vocab = VocabStore.shared
    private let history = HistoryStore.shared
    private let injector = TextInjector()
    private var recordingStartedAt: Date?
    private var recordingFrontmostApp: String?
    private var localEscMonitor: Any?
    private var maxDurationTimer: Timer?

    /// Auto-stop recordings at this length. Above this we hit array-realloc
    /// stalls on the capture queue and the WAV header eventually overflows.
    private static let maxRecordingSeconds: TimeInterval = 10 * 60

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

        // Don't fire the mic permission prompt here. It would appear before
        // the welcome window, out of context. Onboarding's PermissionsStep
        // requests it as part of the flow. AudioRecorder.start() has its own
        // fallback for the edge case where status is still .notDetermined
        // when the user first presses the hotkey.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        AppLogger.log("mic permission at launch: status=\(micStatus.rawValue)")

        setupMenuBar()
        overlayController = OverlayWindowController()
        overlayController.audioLevelProvider = { [weak self] in
            self?.recorder.currentLevel ?? 0
        }

        KeyboardShortcuts.onKeyDown(for: .toggleRecording) { [weak self] in
            AppLogger.log("hotkey toggleRecording fired")
            self?.toggleRecording()
        }

        // Kick off the sidecar install in the background as soon as the app
        // launches. By the time the user reaches the Engine step in onboarding
        // (or relaunches with a broken daemon), the heavy work is mid-flight
        // or done. No-ops cleanly if a daemon is already running.
        SidecarInstaller.shared.ensureRunning()

        // Populate the downloaded-models cache so the menu bar's Model
        // submenu is correct on first open (no flicker / "no models yet"
        // false negative).
        DownloadedModelsCache.shared.refresh()

        // First-launch onboarding, shown once per install.
        if !UserDefaults.standard.bool(forKey: Self.onboardingSeenKey) {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }
    }

    private func showOnboarding() {
        if let w = onboardingWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let window = OnboardingWindowFactory.make { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.onboardingSeenKey)
            self?.onboardingWindow = nil
        }
        onboardingWindow = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.onboardingWindow = nil
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private var micMenu: NSMenu!
    private var modelMenu: NSMenu!
    private var micMenuItem: NSMenuItem!
    private var modelMenuItem: NSMenuItem!
    private var copyLastMenuItem: NSMenuItem!

    private func setupMenuBar() {
        // No keyEquivalents on any of these items. The app runs as .accessory
        // with no main menu, so a status-menu key equivalent only fires while
        // the menu is already open. Showing one implies a global shortcut that
        // doesn't exist. The real global hotkey is registered separately
        // through KeyboardShortcuts, and only Toggle Recording has one.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "OpenLark"
            )
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(
            title: "Toggle Recording (⌘↑)",
            action: #selector(menuToggleRecording),
            keyEquivalent: ""
        ))

        // Puts the most recent transcript back on the clipboard, for when
        // something else has overwritten it since dictating.
        copyLastMenuItem = NSMenuItem(
            title: "Copy Last Transcription",
            action: #selector(copyLastTranscript),
            keyEquivalent: ""
        )
        copyLastMenuItem.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: nil
        )
        menu.addItem(copyLastMenuItem)
        menu.addItem(.separator())

        // Microphone submenu, rebuilt every time the parent menu opens.
        micMenu = NSMenu()
        micMenu.delegate = self
        micMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenuItem.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        micMenuItem.submenu = micMenu
        menu.addItem(micMenuItem)

        // Model submenu, only downloaded models, rebuilt every open.
        modelMenu = NSMenu()
        modelMenu.delegate = self
        modelMenuItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelMenuItem.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
        modelMenuItem.submenu = modelMenu
        menu.addItem(modelMenuItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "History…",
            action: #selector(openHistory),
            keyEquivalent: ""
        ))
        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(openSettings),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Quit OpenLark",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: ""
        ))
        statusItem.menu = menu
    }

    // MARK: - Mic / Model submenus

    fileprivate func rebuildMicMenu() {
        micMenu.removeAllItems()
        let devices = AudioInputs.available()
        let selected = AudioInputs.selectedDeviceID

        let systemDefault = NSMenuItem(
            title: "System Default",
            action: #selector(selectMic(_:)),
            keyEquivalent: ""
        )
        systemDefault.representedObject = NSNull()
        systemDefault.state = (selected == nil) ? .on : .off
        systemDefault.target = self
        micMenu.addItem(systemDefault)

        if !devices.isEmpty {
            micMenu.addItem(.separator())
        }

        for device in devices {
            let item = NSMenuItem(
                title: device.name,
                action: #selector(selectMic(_:)),
                keyEquivalent: ""
            )
            item.representedObject = device.uniqueID
            item.state = (selected == device.uniqueID) ? .on : .off
            item.target = self
            micMenu.addItem(item)
        }

        // Update the parent row title to show the currently-selected device,
        // so users see what's active without opening the submenu.
        let activeName = devices.first { $0.uniqueID == selected }?.name
            ?? "System Default"
        micMenuItem.title = "Microphone: \(activeName)"
    }

    fileprivate func rebuildModelMenu() {
        modelMenu.removeAllItems()
        let downloaded = DownloadedModelsCache.shared.downloadedModels()
        let activeId = UserModelSettings.activeModelId

        if downloaded.isEmpty {
            let empty = NSMenuItem(
                title: "No models downloaded yet",
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            modelMenu.addItem(empty)
            modelMenu.addItem(.separator())
            let openSettings = NSMenuItem(
                title: "Open Settings → Models…",
                action: #selector(openModelsSettings),
                keyEquivalent: ""
            )
            openSettings.target = self
            modelMenu.addItem(openSettings)
        } else {
            for model in downloaded {
                let item = NSMenuItem(
                    title: model.displayName,
                    action: #selector(selectModel(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = model.id
                item.state = (model.id == activeId) ? .on : .off
                item.target = self
                modelMenu.addItem(item)
            }
            modelMenu.addItem(.separator())
            let manage = NSMenuItem(
                title: "Manage models…",
                action: #selector(openModelsSettings),
                keyEquivalent: ""
            )
            manage.target = self
            modelMenu.addItem(manage)
        }

        let activeName = downloaded.first { $0.id == activeId }?.displayName
            ?? ModelRegistry.find(activeId)?.displayName
            ?? "none"
        modelMenuItem.title = "Model: \(activeName)"
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let id = sender.representedObject as? String
        AudioInputs.setSelectedDeviceID(id)
        AppLogger.log("mic selection changed: \(id ?? "system-default")")
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let modelId = sender.representedObject as? String else { return }
        UserDefaults.standard.set(modelId, forKey: UserModelSettings.activeModelIdKey)
        AppLogger.log("active model changed via menu: \(modelId)")
    }

    // MARK: - Copy last transcript

    /// Keeps the row's title showing what would be copied. Enablement is
    /// handled by validateMenuItem.
    fileprivate func refreshCopyLastItem() {
        guard let entry = history.entries.first else {
            copyLastMenuItem.title = "Copy Last Transcription"
            return
        }
        copyLastMenuItem.title = "Copy Last Transcription: \(Self.preview(entry.text))"
    }

    /// Opening few words of a transcript, quoted, for a menu title. Just
    /// enough to recognise which dictation it is without widening the menu.
    private static func preview(_ text: String, maxWords: Int = 2, limit: Int = 20) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return "" }

        var kept = words.prefix(maxWords).joined(separator: " ")
        var truncated = words.count > maxWords
        if kept.count > limit {
            kept = String(kept.prefix(limit)).trimmingCharacters(in: .whitespaces)
            truncated = true
        }
        return "\u{201C}\(kept)\(truncated ? "\u{2026}" : "")\u{201D}"
    }

    @objc private func copyLastTranscript() {
        guard let entry = history.entries.first else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        AppLogger.log("copied last transcript to clipboard (\(entry.text.count) chars)")
    }

    @objc private func menuToggleRecording() {
        toggleRecording()
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
        showSettings()
    }

    /// Opens Settings straight to the Models section, for the menu items that
    /// promise exactly that.
    @objc private func openModelsSettings() {
        showSettings(section: .models)
    }

    /// Passing a section switches an already-open window too, so the menu
    /// items behave the same whether or not Settings is showing.
    private func showSettings(section: SettingsSection? = nil) {
        if let section {
            settingsNavigator.section = section
        }
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let window = SettingsWindowFactory.make(navigator: settingsNavigator)
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
        // Capture the frontmost app NOW, before our overlay or any focus shift.
        // Used for the "Apps used this week" stat.
        recordingFrontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName
        state = .recording
        recordingStartedAt = Date()
        overlayController.show()
        installEscMonitor()
        installMaxDurationTimer()
    }

    private func installMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = Timer.scheduledTimer(
            withTimeInterval: Self.maxRecordingSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                AppLogger.log("hit max recording duration (\(Int(Self.maxRecordingSeconds))s), auto-stopping")
                self.stopAndTranscribe()
            }
        }
    }

    private func removeMaxDurationTimer() {
        maxDurationTimer?.invalidate()
        maxDurationTimer = nil
    }

    private func stopAndTranscribe() {
        guard state == .recording else { return }
        removeEscMonitor()
        removeMaxDurationTimer()
        state = .transcribing
        overlayController.setProcessing()

        guard let wav = recorder.stopAndExportWAV() else {
            AppLogger.log("stopAndTranscribe: no audio captured")
            cancel()
            return
        }
        AppLogger.log("stopAndTranscribe: \(wav.count) bytes captured, sending to sidecar")

        Task { [weak self] in
            guard let self else { return }
            let modelId = UserModelSettings.activeModelId
            let languages = UserModelSettings.selectedLanguageCodes
            let result = await self.sidecar.transcribe(
                wav: wav, modelId: modelId, languages: languages
            )
            self.overlayController.hide()
            switch result {
            case .success(let raw):
                let corrected = self.vocab.correct(raw)
                AppLogger.log("transcribed: \(raw.count) chars raw, \(corrected.count) chars corrected")
                if !corrected.isEmpty {
                    let duration = self.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    self.history.add(
                        text: corrected,
                        durationSeconds: duration,
                        appName: self.recordingFrontmostApp
                    )
                    self.injector.inject(text: corrected)
                }
            case .failure(let err):
                AppLogger.log("transcription failed: \(err)")
                NSSound.beep()
                // Restart the daemon ONLY when it's genuinely wedged (timeout)
                // or unreachable (connect failed). A serverError like
                // "model_missing" is a fast, honest answer - the daemon is fine,
                // the model just isn't downloaded - so restarting would be
                // pointless. The transcribe path never downloads, so a timeout
                // now always means a real wedge, not a legit long download.
                switch err {
                case SidecarClient.SidecarError.timedOut:
                    AppLogger.log("restarting wedged speech engine")
                    SidecarClient.restartDaemon()
                case SidecarClient.SidecarError.connectFailed:
                    AppLogger.log("restarting unreachable speech engine")
                    SidecarClient.restartDaemon()
                case SidecarClient.SidecarError.serverError(let msg) where msg.contains("model not downloaded"):
                    AppLogger.log("active model not downloaded - open Settings → Models to download it")
                default:
                    break
                }
            }
            self.recordingStartedAt = nil
            self.recordingFrontmostApp = nil
            self.state = .idle
        }
    }

    private func cancel() {
        removeEscMonitor()
        removeMaxDurationTimer()
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

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyLastTranscript) {
            return !history.entries.isEmpty
        }
        return true
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem.menu {
            // Trigger a background refresh of the downloaded-models cache so
            // the Model submenu reflects anything the user just downloaded.
            DownloadedModelsCache.shared.refresh()
            rebuildMicMenu()
            rebuildModelMenu()
            refreshCopyLastItem()
        } else if menu === micMenu {
            rebuildMicMenu()
        } else if menu === modelMenu {
            rebuildModelMenu()
        }
    }
}
