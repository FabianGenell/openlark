import AppKit

@MainActor
func runApp() {
    // Must run before any SwiftPM resource-bundle access (KeyboardShortcuts,
    // any future SPM dep using Bundle.module). Will exit the process if the
    // bundle was translocated and a relaunch was scheduled.
    TranslocationGuard.run()

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

MainActor.assumeIsolated { runApp() }
