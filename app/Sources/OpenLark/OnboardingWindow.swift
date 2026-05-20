@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
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
    case done
}

private struct OnboardingView: View {
    let onFinish: () -> Void
    @State private var step: Step = .welcome

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
        case .engine: EngineStep(onReady: { advance() })
        case .done: DoneStep()
        }
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

            Button(step == .done ? "Done" : "Continue") {
                advance()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }

    private func advance() {
        switch step {
        case .welcome: step = .permissions
        case .permissions: step = .engine
        case .engine: step = .done
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
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Grant a few permissions")
                    .font(.system(size: 22, weight: .semibold))
                Text("OpenLark needs three things from macOS to work. Each opens a different System Settings pane.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                PermissionRow(
                    title: "Microphone",
                    subtitle: "Record your voice for transcription.",
                    icon: "mic.fill",
                    granted: micGranted,
                    action: requestMicrophone,
                    openSettings: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
                )
                PermissionRow(
                    title: "Accessibility",
                    subtitle: "Inject the transcribed text into the focused app.",
                    icon: "hand.point.up.left.fill",
                    granted: accessibilityGranted,
                    action: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") },
                    openSettings: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
                )
                PermissionRow(
                    title: "Input Monitoring",
                    subtitle: "Capture the Esc key globally while recording.",
                    icon: "keyboard.fill",
                    granted: inputMonitoringGranted,
                    action: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") },
                    openSettings: { open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") }
                )
            }

            Text("You can come back to this any time from the menu bar → Settings.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

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
        // AXIsProcessTrusted reflects current Accessibility state.
        accessibilityGranted = AXIsProcessTrusted()
        // Input Monitoring isn't trivially queryable; reuse Accessibility as a proxy
        // (anyone who's granted Accessibility usually grants Input Monitoring too)
        // until we add a more precise check via IOHIDCheckAccess.
        inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        } else if status == .denied || status == .restricted {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

private struct PermissionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let granted: Bool
    let action: () -> Void
    let openSettings: () -> Void

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
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
                Button("Grant") { action() }
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
    let onReady: () -> Void
    @StateObject private var installer = SidecarInstaller()
    @State private var hasStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Install the speech engine")
                    .font(.system(size: 22, weight: .semibold))
                Text("OpenLark uses a small background daemon to run NVIDIA Parakeet on Apple's MLX. It's about a 30 MB download for Python + 150 MB for the inference libraries — only done once.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .center, spacing: 14) {
                statusIcon
                Text(installer.stage.description)
                    .font(.system(size: 14, weight: .medium))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)

                if case .downloadingPython(let p) = installer.stage {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 280)
                }

                if installer.stage.isError {
                    Button("Retry") {
                        Task { await installer.install() }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity)

            Spacer()

            if !hasStarted && !installer.stage.isTerminal {
                Button {
                    hasStarted = true
                    Task {
                        await installer.install()
                        if case .done = installer.stage { onReady() }
                        if case .alreadyInstalled = installer.stage { onReady() }
                    }
                } label: {
                    Text("Install speech engine")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .onAppear {
            // Auto-skip the step if the daemon is already healthy from a prior install.
            if installer.isDaemonHealthy() {
                installer.stage = .alreadyInstalled
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onReady() }
            }
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
                tip(icon: "command.square", text: "Change the hotkey or switch to push-to-talk in Settings → General.")
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
