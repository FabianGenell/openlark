import AppKit

/// Writes the transcribed text into the focused text field by:
///   1. Stashing existing pasteboard contents
///   2. Writing the new text
///   3. Synthesising ⌘V
///   4. Restoring the original pasteboard after a short delay
///
/// Per the spec, the text also remains on the clipboard so the user can ⌘V
/// again if the auto-paste misses. We do that by NOT restoring if restoration
/// would lose the transcript — actually we always restore. The user pressing
/// ⌘+↑ again before pasting won't lose it because each transcript is fresh.
///
/// Actually the user explicitly wants the text to STAY on the clipboard after
/// paste — so we skip the restore step.
final class TextInjector {
    func inject(text: String) {
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Small delay so the focused app has time to settle after our overlay closed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Self.sendCommandV()
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }
}
