import AppKit
import Foundation
import Security

// macOS routes quarantined apps through a read-only path under
// /private/var/folders/.../AppTranslocation/<uuid>/d/. Swift Package Manager's
// `Bundle.module` accessor fails to resolve the resource bundle from that
// path, which makes any SPM library that uses `Bundle.module` crash on init.
// For us that's KeyboardShortcuts.RecorderCocoa, which hits an assertion
// failure during the onboarding hotkey step and takes the whole app down.
//
// Without Apple Developer ID notarization we can't prevent the OS from
// quarantining the bundle, but we can detect the translocation at launch,
// strip the quarantine xattr from the *original* on-disk bundle, and relaunch
// from there. Once quarantine is gone, macOS stops translocating on
// subsequent launches and Bundle.module resolves correctly.

@_silgen_name("SecTranslocateCreateOriginalPathForURL")
private func SecTranslocateCreateOriginalPathForURL(
    _ translocatedPath: CFURL,
    _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?
) -> Unmanaged<CFURL>?

enum TranslocationGuard {
    private static let relaunchEnvVar = "OPENLARK_GUARD_RELAUNCH"

    static var isTranslocated: Bool {
        Bundle.main.bundlePath.contains("/AppTranslocation/")
    }

    /// Call once, very early in `main`, before any AppKit / SwiftUI / SPM
    /// library code touches `Bundle.module`. If the running bundle is
    /// translocated, attempts to de-quarantine the source bundle and
    /// relaunch from there; the current process then exits.
    @MainActor
    static func run() {
        guard isTranslocated else { return }

        let alreadyRetried = ProcessInfo.processInfo.environment[relaunchEnvVar] == "1"
        if alreadyRetried {
            // The previous relocation attempt didn't take (probably a
            // read-only source location like a DMG mount). Tell the user
            // what to do instead of spinning in a relaunch loop.
            showRelocateAlert()
            exit(0)
        }

        let bundleURL = Bundle.main.bundleURL
        guard let originalURL = originalPath(for: bundleURL),
              originalURL.path != bundleURL.path
        else {
            showRelocateAlert()
            exit(0)
        }

        clearQuarantine(at: originalURL.path)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = true
        var env = ProcessInfo.processInfo.environment
        env[relaunchEnvVar] = "1"
        config.environment = env

        let sema = DispatchSemaphore(value: 0)
        var relaunchError: Error?
        NSWorkspace.shared.openApplication(
            at: originalURL,
            configuration: config
        ) { _, error in
            relaunchError = error
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 5)

        if relaunchError != nil {
            showRelocateAlert()
        }
        exit(0)
    }

    private static func originalPath(for url: URL) -> URL? {
        guard let cf = SecTranslocateCreateOriginalPathForURL(url as CFURL, nil) else {
            return nil
        }
        return cf.takeRetainedValue() as URL
    }

    private static func clearQuarantine(at path: String) {
        let task = Process()
        task.launchPath = "/usr/bin/xattr"
        task.arguments = ["-cr", path]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // Best effort. If xattr fails (read-only mount, permissions),
            // the relaunch will either succeed anyway because Finder's drag
            // disabled translocation, or it'll loop once and we'll show the
            // alert path.
        }
    }

    @MainActor
    private static func showRelocateAlert() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Move OpenLark to your Applications folder"
        alert.informativeText = """
            macOS is running OpenLark from a sandboxed temporary location, which prevents it from loading some required resources.

            To fix this:

            1. Quit OpenLark.
            2. Drag OpenLark.app into your Applications folder (use Finder, not Terminal).
            3. Open it from Applications.

            If you've already moved it but still see this message, open Terminal and run:

                xattr -cr /Applications/OpenLark.app
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        _ = alert.runModal()
    }
}
