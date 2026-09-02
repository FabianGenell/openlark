@preconcurrency import AVFoundation
import Foundation

/// Lightweight wrapper around AVCaptureDevice enumeration for audio input.
/// Persisted choice = uniqueID; `nil` means "system default".
struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let uniqueID: String
    let name: String

    var id: String { uniqueID }
}

enum AudioInputs {
    static let selectedDeviceKey = "selectedAudioInputDeviceID"

    /// All available audio input devices on this Mac. Empty if none are
    /// connected or the mic permission isn't granted yet.
    static func available() -> [AudioInputDevice] {
        // Built-in + external mics + USB + Bluetooth/AirPods etc. macOS
        // 14+ supports these device types via .external, so we keep a broad
        // catch-net so AirPods, USB mics, and aggregate devices all show up.
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        return session.devices.map {
            AudioInputDevice(uniqueID: $0.uniqueID, name: $0.localizedName)
        }
    }

    /// Currently selected device id, or nil for "system default".
    static var selectedDeviceID: String? {
        let raw = UserDefaults.standard.string(forKey: selectedDeviceKey)
        // "" stored explicitly = follow system default
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    static func setSelectedDeviceID(_ id: String?) {
        UserDefaults.standard.set(id ?? "", forKey: selectedDeviceKey)
    }

    /// Resolved AVCaptureDevice. Uses the persisted id if present and the
    /// device is still connected, otherwise falls back to the system default.
    static func currentDevice() -> AVCaptureDevice? {
        if let id = selectedDeviceID,
           let dev = AVCaptureDevice(uniqueID: id) {
            return dev
        }
        return AVCaptureDevice.default(for: .audio)
    }
}
