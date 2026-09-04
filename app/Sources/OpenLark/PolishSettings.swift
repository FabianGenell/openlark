import Foundation

/// One row in the polish-model picker.
///
/// Deliberately separate from `ModelDescriptor`. Speech models and polish
/// models are downloaded and deleted through the same daemon commands, but
/// nothing about a language model's metadata (languages, backend, realtime
/// factor) means the same thing for a text model, so sharing the type would
/// only produce fields that are meaningless on one side or the other.
struct PolishModelDescriptor: Identifiable, Hashable, Sendable {
    let id: String              // canonical id sent to the sidecar
    let displayName: String
    let approxSizeMB: Int
    let speedLabel: String      // "Fastest", "Fast", "Balanced"
    let summary: String
    let recommendedDefault: Bool
}

enum PolishRegistry {
    /// Order matters. This is the order shown in Settings → Polish.
    static let all: [PolishModelDescriptor] = [
        PolishModelDescriptor(
            id: "qwen2.5-7b-instruct-4bit",
            displayName: "Qwen2.5 7B",
            approxSizeMB: 4097,
            speedLabel: "Considered",
            summary: "The steadiest judgement on offer. Worth it for a profile that writes email, where a dropped clause matters.",
            recommendedDefault: false
        ),
        PolishModelDescriptor(
            id: "qwen3-4b-instruct-4bit",
            displayName: "Qwen3 4B",
            approxSizeMB: 2173,
            speedLabel: "Balanced",
            summary: "A step up from 3B for half the size of 7B. Good middle ground for longer dictation.",
            recommendedDefault: false
        ),
        PolishModelDescriptor(
            id: "qwen2.5-3b-instruct-4bit",
            displayName: "Qwen2.5 3B",
            approxSizeMB: 1667,
            speedLabel: "Fast",
            summary: "The best judgement of the three. Punctuates, paragraphs, and still sounds like you.",
            recommendedDefault: true
        ),
        PolishModelDescriptor(
            id: "qwen2.5-1.5b-instruct-4bit",
            displayName: "Qwen2.5 1.5B",
            approxSizeMB: 839,
            speedLabel: "Fastest",
            summary: "Half the download. Choppier when a dictation runs long without a pause.",
            recommendedDefault: false
        ),
        PolishModelDescriptor(
            id: "qwen3-1.7b-4bit",
            displayName: "Qwen3 1.7B",
            approxSizeMB: 938,
            speedLabel: "Fast",
            summary: "The lightest touch. Clears filler and repeats, barely reshapes anything else.",
            recommendedDefault: false
        ),
    ]

    static let defaultModelId = "qwen2.5-3b-instruct-4bit"

    static func find(_ id: String) -> PolishModelDescriptor? {
        all.first { $0.id == id }
    }
}

/// AppStorage-backed settings for the polish pass. SwiftUI views observe via
/// @AppStorage; the hotkey handler reads these directly.
enum PolishSettings {
    /// The main switch. Off by default; the menu bar checkbox, the overlay's
    /// mic button and the Settings toggle all read and write this one value, so
    /// there is a single answer to "is polish on" wherever you look.
    static let polishByDefaultKey = "polishByDefault"

    static var polishByDefault: Bool {
        get { UserDefaults.standard.bool(forKey: polishByDefaultKey) }
        set { UserDefaults.standard.set(newValue, forKey: polishByDefaultKey) }
    }
}
