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
    private let polishProfiles = PolishProfileStore.shared
    private let history = HistoryStore.shared
    private let injector = TextInjector()
    private let updater = Updater()
    private var recordingStartedAt: Date?
    private var recordingFrontmostApp: String?
    private var localEscMonitor: Any?
    private var maxDurationTimer: Timer?
    /// Whether the recording in flight gets a polish pass. Read at the moment
    /// it's needed, so flipping the switch mid-recording still counts.
    private var polishRequested: Bool { PolishSettings.polishByDefault }

    /// Auto-stop recordings at this length. Above this we hit array-realloc
    /// stalls on the capture queue and the WAV header eventually overflows.
    private static let maxRecordingSeconds: TimeInterval = 10 * 60

    enum State { case idle, recording, transcribing }
    private var state: State = .idle
    /// Bumped whenever a run ends, by finishing or by being cancelled. An
    /// in-flight transcription compares the generation it started in against
    /// this before touching anything, so a superseded run can't hide the
    /// overlay of the recording that replaced it or paste its stale text.
    private var runGeneration = 0
    /// The transcript as dictated, held while polish runs so "Use original"
    /// has something to hand over without waiting for the pass to finish.
    private var pendingUnpolished: String?

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

        installMainMenu()
        setupMenuBar()
        overlayController = OverlayWindowController()
        overlayController.audioLevelProvider = { [weak self] in
            self?.recorder.currentLevel ?? 0
        }
        overlayController.onTogglePolish = { [weak self] in
            guard let self else { return }
            self.setPolish(enabled: !self.polishRequested)
        }
        overlayController.onSkipPolish = { [weak self] in
            self?.skipPolish()
        }
        overlayController.onStop = { [weak self] in
            self?.stopAndTranscribe()
        }
        overlayController.onCancel = { [weak self] in
            self?.cancel()
        }
        overlayController.onSelectProfile = { [weak self] index in
            guard let self else { return }
            let profiles = self.polishProfiles.profiles
            guard profiles.indices.contains(index) else { return }
            self.polishProfiles.setActive(profiles[index])
            self.pushProfilesToOverlay()
            AppLogger.log("polish profile switched to \(profiles[index].name)")
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

    /// A main menu, purely so text fields get the standard editing shortcuts.
    ///
    /// ⌘A, ⌘C, ⌘V, ⌘X and ⌘Z are not built into NSTextField; they are key
    /// equivalents on the application's Edit menu, which dispatches them down
    /// the responder chain. An .accessory app has no main menu by default, so
    /// every text field in Settings silently ignored all of them - you could
    /// type into the polish instructions but not paste a prompt into them.
    ///
    /// Nothing here is ever displayed: an .accessory app shows no menu bar.
    /// The menu exists only so the key equivalents resolve.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // macOS treats the first item as the application menu. It stays empty;
        // its only job is to hold the conventional first slot.
        mainMenu.addItem(NSMenuItem())

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        mainMenu.addItem(editItem)

        // ⌘W to close Settings or History, which an accessory app also lacks.
        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    private var micMenu: NSMenu!
    private var modelMenu: NSMenu!
    private var toggleMenuItem: NSMenuItem!
    private var profileMenu: NSMenu!
    private var profileMenuItem: NSMenuItem!
    private var micMenuItem: NSMenuItem!
    private var modelMenuItem: NSMenuItem!
    private var copyLastMenuItem: NSMenuItem!

    private func setupMenuBar() {
        // No images on any row either. An item is laid out [state][image][title],
        // so once one row carries a checkmark the rows with icons and the rows
        // with neither end up on three different title columns. Text-only plus
        // the state column is what a Mac menu is supposed to look like anyway.
        //
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
        toggleMenuItem = NSMenuItem(
            title: "Toggle Recording",
            action: #selector(menuToggleRecording),
            keyEquivalent: ""
        )
        menu.addItem(toggleMenuItem)

        // Puts the most recent transcript back on the clipboard, for when
        // something else has overwritten it since dictating.
        copyLastMenuItem = NSMenuItem(
            title: "Copy Last Transcription",
            action: #selector(copyLastTranscript),
            keyEquivalent: ""
        )
        menu.addItem(copyLastMenuItem)
        menu.addItem(.separator())

        // Microphone submenu, rebuilt every time the parent menu opens.
        micMenu = NSMenu()
        micMenu.delegate = self
        micMenuItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micMenuItem.submenu = micMenu
        menu.addItem(micMenuItem)

        // Model submenu, only downloaded models, rebuilt every open.
        modelMenu = NSMenu()
        modelMenu.delegate = self
        modelMenuItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelMenuItem.submenu = modelMenu
        menu.addItem(modelMenuItem)

        // Off plus the profiles, in one list. Polish being on and which profile
        // is running are the same decision, so they're the same control.
        // Rebuilt on every open, like the mic and model submenus.
        profileMenu = NSMenu()
        profileMenu.delegate = self
        profileMenuItem = NSMenuItem(title: "Polish", action: nil, keyEquivalent: "")
        profileMenuItem.submenu = profileMenu
        menu.addItem(profileMenuItem)

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
        menu.addItem(updater.menuItem)
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
        let systemDefaultTitle = AudioInputs.systemDefaultName()
            .map { "System Default (\($0))" } ?? "System Default"

        let systemDefault = NSMenuItem(
            title: systemDefaultTitle,
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
            ?? systemDefaultTitle
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

    fileprivate func rebuildProfileMenu() {
        profileMenu.removeAllItems()
        let on = PolishSettings.polishByDefault
        let active = polishProfiles.active

        let off = NSMenuItem(title: "Off", action: #selector(selectProfile(_:)), keyEquivalent: "")
        off.representedObject = NSNull()
        off.state = on ? .off : .on
        off.target = self
        profileMenu.addItem(off)
        profileMenu.addItem(.separator())

        for profile in polishProfiles.profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.representedObject = profile.id.uuidString
            item.state = (on && profile.id == active?.id) ? .on : .off
            item.target = self
            profileMenu.addItem(item)
        }

        profileMenu.addItem(.separator())
        let manage = NSMenuItem(
            title: "Edit profiles…",
            action: #selector(openPolishSettings),
            keyEquivalent: ""
        )
        manage.target = self
        profileMenu.addItem(manage)

        profileMenuItem.title = "Polish: " + (on ? (active?.name ?? "on") : "Off")
    }

    /// Picking a profile turns polish on as well; picking Off turns it off and
    /// leaves the profile alone, so it comes back to the same one next time.
    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let profile = polishProfiles.profiles.first(where: { $0.id == id }) else {
            setPolish(enabled: false)
            return
        }
        polishProfiles.setActive(profile)
        setPolish(enabled: true)
        AppLogger.log("polish profile changed via menu: \(profile.name)")
    }

    @objc private func openPolishSettings() {
        showSettings(section: .polish)
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

    /// Both record rows spell out their current shortcut. They're rebindable in
    /// Settings, so a hardcoded "(⌘↑)" goes stale the moment someone changes one.
    fileprivate func refreshRecordingItems() {
        toggleMenuItem.title = "Toggle Recording" + Self.shortcutSuffix(.toggleRecording)
    }

    /// The one place the polish switch is written, so the menu checkbox and the
    /// overlay's mic button can't drift apart.
    private func setPolish(enabled: Bool) {
        PolishSettings.polishByDefault = enabled
        overlayController.polishOn = enabled
        // Re-read the catalogue: a model may have finished downloading, or been
        // deleted, since the last time the pill was told anything.
        DownloadedModelsCache.shared.refresh()
        pushProfilesToOverlay()
        AppLogger.log("polish set to \(enabled)")
    }

    private static func shortcutSuffix(_ name: KeyboardShortcuts.Name) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return "" }
        return " (\(shortcut))"
    }

    private func pushProfilesToOverlay() {
        overlayController.setProfiles(
            polishProfiles.profiles.map(\.name),
            active: polishProfiles.active?.name ?? ""
        )
        overlayController.polishReady = polishIsUsable
    }

    /// Whether polish can actually run: the active profile's model has to be
    /// on disk. Without this the pill showed the armed sparkle regardless, so a
    /// profile pinned to a model that was never downloaded looked identical to
    /// a working one and quietly pasted the raw transcript every time.
    private var polishIsUsable: Bool {
        DownloadedModelsCache.shared.downloadedIds.contains(polishProfiles.activeModelId)
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
        overlayController.polishOn = polishRequested
        DownloadedModelsCache.shared.refresh()
        pushProfilesToOverlay()
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
        // The Esc tap stays armed through transcription and polish. Those are
        // the seconds where a dictation is most obviously not wanted any more -
        // long enough to change your mind, and until now the only key that did
        // anything was one that started a new recording.
        removeMaxDurationTimer()
        state = .transcribing
        overlayController.setTranscribing()

        guard let wav = recorder.stopAndExportWAV() else {
            AppLogger.log("stopAndTranscribe: no audio captured")
            cancel()
            return
        }
        AppLogger.log("stopAndTranscribe: \(wav.count) bytes captured, sending to sidecar")

        let generation = runGeneration
        Task { [weak self] in
            guard let self else { return }
            let modelId = UserModelSettings.activeModelId
            let languages = UserModelSettings.selectedLanguageCodes
            let result = await self.sidecar.transcribe(
                wav: wav, modelId: modelId, languages: languages
            )
            // Esc, or a new recording, happened while this was in flight.
            // Everything below either paints the overlay or types into the
            // user's document, and both belong to whatever is happening now.
            guard generation == self.runGeneration else {
                AppLogger.log("discarding superseded transcription (generation \(generation))")
                return
            }
            switch result {
            case .success(let raw):
                // Vocab first, so the polish model reads the right spelling of
                // names instead of guessing at a phonetic near-miss.
                var corrected = self.vocab.correct(raw)
                AppLogger.log("transcribed: \(raw.count) chars raw, \(corrected.count) chars corrected")
                let unpolished = corrected
                var profileUsed: String?
                if self.polishRequested, !corrected.isEmpty {
                    self.pendingUnpolished = unpolished
                    EscEventTap.shared.setSkipArmed(true)
                    self.overlayController.setPolishing()
                    profileUsed = self.polishProfiles.active?.name
                    corrected = await self.polished(corrected, generation: generation)
                    // Polish is another second or two of waiting, so check again.
                    // "Use original" bumps the generation too, having already
                    // delivered the raw transcript itself.
                    guard generation == self.runGeneration else {
                        AppLogger.log("discarding superseded polish (generation \(generation))")
                        return
                    }
                    EscEventTap.shared.setSkipArmed(false)
                    self.pendingUnpolished = nil
                }
                self.overlayController.hide()
                self.deliver(text: corrected, original: unpolished, profile: profileUsed)
            case .failure(let err):
                self.overlayController.hide()
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
            self.removeEscMonitor()
            EscEventTap.shared.setSkipArmed(false)
            self.recordingStartedAt = nil
            self.recordingFrontmostApp = nil
            self.runGeneration &+= 1
            self.state = .idle
        }
    }

    /// Hands a finished transcript to history and to the focused app. One
    /// place, so skipping polish lands exactly the way finishing it does.
    private func deliver(text: String, original: String, profile: String?) {
        guard !text.isEmpty else { return }
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        history.add(
            text: text,
            durationSeconds: duration,
            appName: recordingFrontmostApp,
            originalText: original,
            polishProfile: profile
        )
        injector.inject(text: text)
    }

    /// Take the dictation as spoken and abandon the polish in flight.
    ///
    /// The polish request can't be recalled from the daemon, so it runs to
    /// completion and its result is discarded by the generation check. What
    /// matters is that the text lands now rather than in two seconds.
    private func skipPolish() {
        guard state == .transcribing, let text = pendingUnpolished else { return }
        AppLogger.log("polish skipped, delivering the transcript as dictated")
        runGeneration &+= 1
        EscEventTap.shared.setSkipArmed(false)
        pendingUnpolished = nil
        removeEscMonitor()
        overlayController.hide()
        deliver(text: text, original: text, profile: nil)
        recordingStartedAt = nil
        recordingFrontmostApp = nil
        state = .idle
    }

    /// Runs the polish pass, and returns the input untouched if anything at
    /// all goes wrong. A dictation that reaches the clipboard slightly rough is
    /// a far better outcome than one that doesn't reach it at all, so every
    /// failure here is non-fatal.
    private func polished(_ text: String, generation: Int) async -> String {
        let modelId = PolishProfileStore.shared.activeModelId
        let result = await sidecar.polish(
            text: text,
            modelId: modelId,
            instruction: PolishProfileStore.shared.activeInstruction,
            temperature: PolishProfileStore.shared.activeTemperature,
            onProgress: { [weak self] value in
                Task { @MainActor in
                    guard let self, generation == self.runGeneration else { return }
                    // A polish abandoned by Tab or Escape keeps streaming from
                    // the daemon, and the bar is monotonic, so an unguarded
                    // frame from the previous dictation would shove the next
                    // one's progress most of the way to done.
                    self.overlayController.setPolishProgress(value)
                }
            }
        )
        switch result {
        case .success(let polish):
            if polish.polished {
                AppLogger.log("polished: \(text.count) chars in, \(polish.text.count) chars out")
                // Polishing can undo a vocab fix by re-casing or re-spacing a
                // name. Re-running is cheap and leaves already-correct text alone.
                return vocab.correct(polish.text)
            }
            AppLogger.log("polish discarded by the daemon (\(polish.reason ?? "no reason")), keeping the raw transcript")
            return text
        case .failure(let err):
            AppLogger.log("polish failed: \(err), keeping the raw transcript")
            if case SidecarClient.SidecarError.serverError(let msg) = err,
               msg.contains("model not downloaded") || msg.contains("no polish support") {
                showPolishSetupNoticeOnce()
            }
            return text
        }
    }

    /// Shown at most once. Someone can press the polish hotkey having never
    /// opened Settings, and silently pasting the unpolished text would look
    /// like the hotkey did nothing.
    private static let polishNoticeShownKey = "polishSetupNoticeShown"

    private func showPolishSetupNoticeOnce() {
        guard !UserDefaults.standard.bool(forKey: Self.polishNoticeShownKey) else { return }

        let alert = NSAlert()
        alert.messageText = "Polish needs a small model downloaded first"
        alert.informativeText = "Your dictation was pasted as-is. Download a polish model and it'll clean up your speech from then on."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        // Only "Open Settings" retires the notice. Marking it shown before the
        // modal made "Not Now" mean "never again", which is not what it says.
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: Self.polishNoticeShownKey)
            showSettings(section: .models)
        }
    }

    /// Esc, at any point between starting a recording and the text landing.
    ///
    /// While transcribing or polishing there is nothing to stop on the daemon
    /// side - the request is already in flight and the socket read can't be
    /// interrupted from here - so cancelling means the result is discarded
    /// rather than never produced. Bumping the generation is what does it: the
    /// in-flight task checks it before touching the overlay or pasting, so it
    /// returns quietly instead of typing into whatever you moved on to.
    private func cancel() {
        // Esc arrives through a CGEventTap that defers to the main queue, so a
        // press in the same run-loop turn as the stop hotkey lands after
        // stopAndTranscribe() has already moved to .transcribing. Without this
        // guard, cancel() would drop the state back to .idle underneath a live
        // transcription; the user starts a new recording, and the old task then
        // hides the new overlay and pastes its own text.
        guard state != .idle else { return }
        AppLogger.log("cancelled during \(state)")
        removeEscMonitor()
        removeMaxDurationTimer()
        EscEventTap.shared.setSkipArmed(false)
        runGeneration &+= 1
        pendingUnpolished = nil
        recorder.cancel()
        overlayController.hide()
        recordingStartedAt = nil
        recordingFrontmostApp = nil
        state = .idle
    }

    // MARK: - Esc monitor

    private func installEscMonitor() {
        // Use a CGEventTap so Esc cancels recording from any app while overlay is up,
        // without us having to register Esc as a global hotkey (which would
        // break Esc behaviour everywhere else).
        EscEventTap.shared.enable(
            onEsc: { @Sendable in
                DispatchQueue.main.async { [weak self] in self?.cancel() }
            },
            onSkip: { @Sendable in
                DispatchQueue.main.async { [weak self] in self?.skipPolish() }
            }
        )
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
            rebuildProfileMenu()
            refreshRecordingItems()
            refreshCopyLastItem()
        } else if menu === micMenu {
            rebuildMicMenu()
        } else if menu === modelMenu {
            rebuildModelMenu()
        } else if menu === profileMenu {
            rebuildProfileMenu()
        }
    }
}
