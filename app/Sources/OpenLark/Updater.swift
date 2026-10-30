import AppKit
import Sparkle

/// Sparkle, checking the appcast published with each release once a day. Feed
/// URL and signing key live in Info.plist.
///
/// OpenLark is a menu bar app, so a scheduled check that finds an update has no
/// window of ours to sit in front of: Sparkle would open its alert behind
/// whatever app is in use, and pulling it forward instead would steal focus
/// from the text field a dictation is about to paste into. So a scheduled
/// update is announced in the menu, and the alert comes up when it's clicked.
@MainActor
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private static let idleTitle = "Check for Updates…"

    let menuItem = NSMenuItem(title: idleTitle, action: nil, keyEquivalent: "")
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        menuItem.target = controller
        menuItem.action = #selector(SPUStandardUpdaterController.checkForUpdates(_:))
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Sparkle proposes immediate focus right after launch or after the Mac
    /// has been idle, when an alert can't interrupt anything. Otherwise we take
    /// it and wait for the menu to be opened.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            menuItem.title = "Update to \(version)…"
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { menuItem.title = Self.idleTitle }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { menuItem.title = Self.idleTitle }
    }
}
