import AppKit

/// Captures Escape, and Tab while polish is running, globally and without
/// registering either as a permanent hotkey. Requires Input Monitoring or
/// Accessibility permission (the system prompts the first time the tap is
/// created).
final class EscEventTap: @unchecked Sendable {
    static let shared = EscEventTap()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let lock = NSLock()
    private var onEsc: (() -> Void)?
    private var onSkip: (() -> Void)?
    private var skipArmed = false

    /// Arms Tab, for the second or two the polish pass is running.
    ///
    /// Tab is swallowed only in that window, and only while the overlay is
    /// showing "Use original", so the key keeps its normal meaning everywhere
    /// else. That window is also the one moment the key is safe to take: the
    /// dictation is already finished and the user is waiting for text to land,
    /// not tabbing between fields.
    func setSkipArmed(_ armed: Bool) {
        lock.lock()
        skipArmed = armed
        lock.unlock()
    }

    func enable(
        onEsc: @escaping @Sendable () -> Void,
        onSkip: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        self.onEsc = onEsc
        self.onSkip = onSkip
        let alreadyActive = tap != nil
        lock.unlock()
        if alreadyActive { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<EscEventTap>.fromOpaque(refcon).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            AppLogger.log("CGEvent.tapCreate failed, accessibility permission missing? See README for fix.")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        lock.lock()
        // Re-check inside lock to avoid double-create on concurrent enable.
        if self.tap == nil {
            self.tap = newTap
            self.runLoopSource = source
            lock.unlock()
        } else {
            // Lost the race, tear down the duplicate we just built.
            lock.unlock()
            CGEvent.tapEnable(tap: newTap, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(newTap)
        }
    }

    func disable() {
        lock.lock()
        let tap = self.tap
        let source = self.runLoopSource
        self.tap = nil
        self.runLoopSource = nil
        self.onEsc = nil
        self.onSkip = nil
        self.skipArmed = false
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 53 /* Escape */ {
            lock.lock()
            let cb = onEsc
            lock.unlock()
            cb?()
            return nil // swallow
        }
        if keyCode == 48 /* Tab */ {
            lock.lock()
            let armed = skipArmed
            let cb = onSkip
            lock.unlock()
            if armed {
                cb?()
                return nil // swallow
            }
        }
        return Unmanaged.passUnretained(event)
    }
}
