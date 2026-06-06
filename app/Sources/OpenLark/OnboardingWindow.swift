@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

enum OnboardingWindowFactory {
    @MainActor
    static func make(onFinish: @escaping () -> Void) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Welcome to OpenLark"
        window.isReleasedWhenClosed = false
        window.center()

        let host = NSHostingView(rootView: OnboardingView(onFinish: {
            onFinish()
            window.close()
        }))
        window.contentView = host
        return window
    }
}

private enum Step: Int, CaseIterable {
    case welcome
    case permissions
    case engine
    case hotkey
    case done
}

private struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var step: Step = .welcome
    @ObservedObject private var installer = SidecarInstaller.shared

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 36)
                .padding(.top, 32)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
        .frame(width: 560, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .engine: EngineStep()
        case .hotkey: HotkeyStep()
        case .done: DoneStep()
        }
    }

    /// True if we should block the user from advancing past the current step.
    /// Only applies to the Engine step while an install is in flight.
    private var blockAdvance: Bool {
        step == .engine && !installer.stage.isTerminal
    }

    private var footer: some View {
        HStack {
            // Progress dots
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            if step != .welcome {
                Button("Back") { goBack() }
                    .keyboardShortcut(.cancelAction)
            }

            Button(continueLabel) {
                advance()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(blockAdvance)
        }
    }

    private var continueLabel: String {
        if step == .done { return "Done" }
        if step == .engine, !installer.stage.isTerminal { return "Installing…" }
        return "Continue"
    }

    private func advance() {
        switch step {
        case .welcome: step = .permissions
        case .permissions: step = .engine
        case .engine:
            step = .hotkey
            // Mark onboarding as seen the moment the user reaches the hotkey
            // step. Permissions + engine are the only things the app actually
            // needs to function — the hotkey defaults to ⌘↑ even if this step
            // is skipped or crashes. Setting the flag here prevents the
            // infinite-onboarding loop if anything goes wrong from this point
            // on (e.g. the KeyboardShortcuts recorder failing under app
            // translocation, which the TranslocationGuard should already have
            // prevented but we want defense-in-depth).
            UserDefaults.standard.set(true, forKey: AppDelegate.onboardingSeenKey)
        case .hotkey: step = .done
        case .done: onFinish()
        }
    }

    private func goBack() {
        guard let prev = Step(rawValue: step.rawValue - 1) else { return }
        step = prev
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .center, spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.primary)
                .padding(.top, 12)

            Text("Welcome to OpenLark")
                .font(.system(size: 26, weight: .semibold))

            Text("Local voice dictation for macOS. Press your hotkey to record, press it again to transcribe and paste. Nothing leaves your machine.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

            Spacer()

            HStack(spacing: 22) {
                feature(icon: "lock.shield", title: "Private", detail: "On-device only")
                feature(icon: "bolt", title: "Fast", detail: "~150 ms warm")
                feature(icon: "dollarsign.circle", title: "Free", detail: "No API keys")
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feature(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 100)
    }
}

private struct PermissionsStep: View {
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var inputMonitoringGranted = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant a few permissions")
                    .font(.system(size: 22, weight: .semibold))
                Text("Click each button. The first shows a macOS prompt; the other two open System Settings — toggle the OpenLark switch on.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Microphone",
                    subtitle: "Record your voice for transcription.",
                    helper: "macOS will show a permission prompt.",
                    icon: "mic.fill",
                    buttonLabel: "Allow",
                    granted: micGranted,
                    action: requestMicrophone
                )
                PermissionRow(
                    title: "Accessibility",
                    subtitle: "Paste transcribed text into the focused app.",
                    helper: "System Settings will open — toggle the OpenLark switch on.",
                    icon: "hand.point.up.left.fill",
                    buttonLabel: "Open Settings",
                    granted: accessibilityGranted,
                    action: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
                )
                PermissionRow(
                    title: "Input Monitoring",
                    subtitle: "Catch the Esc key globally while recording.",
                    helper: "System Settings will open — toggle the OpenLark switch on.",
                    icon: "keyboard.fill",
                    buttonLabel: "Open Settings",
                    granted: inputMonitoringGranted,
                    action: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") }
                )
            }

            Text("Status updates here automatically when you toggle a switch in System Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .onAppear { startPolling() }
        .onDisappear { pollTimer?.invalidate() }
    }

    private func startPolling() {
        refresh()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    @MainActor
    private func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        micGranted = (mic == .authorized)
        accessibilityGranted = AXIsProcessTrusted()
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if status == .denied || status == .restricted {
            // Already denied at the system level — only System Settings can flip it.
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
        // status == .authorized: poll will pick it up
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let helper: String
    let icon: String
    let buttonLabel: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(granted ? Color.green.opacity(0.15) : Color.white.opacity(0.06))
                    .frame(width: 38, height: 38)
                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(granted ? .green : .primary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                Text(granted ? subtitle : helper)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Granted")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                    .foregroundStyle(.green)
            } else {
                Button(buttonLabel) { action() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}

private struct EngineStep: View {
    @ObservedObject private var installer = SidecarInstaller.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speech engine")
                    .font(.system(size: 22, weight: .semibold))
                Text("One-time setup — about 180 MB.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .center, spacing: 14) {
                statusIcon
                Text(installer.stage.description)
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if case .downloading(let p) = installer.stage {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                }

                if installer.stage.isError {
                    Button("Retry") {
                        installer.ensureRunning()
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()
        }
        .onAppear {
            // App launched with onboarding open and no daemon — make sure the
            // installer is running. ensureRunning() is idempotent.
            installer.ensureRunning()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch installer.stage {
        case .done, .alreadyInstalled:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.orange)
        case .idle:
            Image(systemName: "cpu")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
        default:
            ProgressView()
                .scaleEffect(1.2)
        }
    }
}

private struct HotkeyStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick a hotkey")
                    .font(.system(size: 22, weight: .semibold))
                Text("Press the keys you want to use to start dictating from any app. Default is ⌘↑.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Toggle recording")
                    .font(.system(size: 14))
                Spacer()
                KeyboardShortcuts.Recorder(for: .toggleRecording)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
            )

            Spacer()

            Text("You can change this any time from menu bar → Settings → General.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct DoneStep: View {
    var body: some View {
        VStack(alignment: .center, spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.green)
                .padding(.top, 12)

            Text("You're set")
                .font(.system(size: 26, weight: .semibold))

            Text("Try it now — go to any text field, press your hotkey, dictate a sentence, press it again. The text will appear at your cursor and on the clipboard.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 8) {
                tip(icon: "menubar.arrow.up.rectangle", text: "OpenLark lives in the menu bar — click the waveform icon for History, Settings, and Vocabulary.")
                tip(icon: "text.book.closed", text: "Add custom words and snippets in Settings → Vocabulary for things the model gets wrong.")
                tip(icon: "command.square", text: "Change the hotkey any time from Settings → General.")
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func tip(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
