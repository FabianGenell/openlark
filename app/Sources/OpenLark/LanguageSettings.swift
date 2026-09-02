import Foundation

/// User-facing language. Code is the ISO-639-1 two-letter code Whisper
/// expects (e.g. "sv" for Swedish).
struct Language: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    let nativeName: String

    var id: String { code }
}

enum LanguageCatalog {
    /// The most common Whisper-supported languages. Ordered roughly by
    /// global usage / likely-relevance for users picking a few. Whisper
    /// supports ~99, so we surface a curated subset to keep the picker sane.
    static let all: [Language] = [
        .init(code: "en", name: "English",    nativeName: "English"),
        .init(code: "sv", name: "Swedish",    nativeName: "Svenska"),
        .init(code: "es", name: "Spanish",    nativeName: "Español"),
        .init(code: "pt", name: "Portuguese", nativeName: "Português"),
        .init(code: "fr", name: "French",     nativeName: "Français"),
        .init(code: "de", name: "German",     nativeName: "Deutsch"),
        .init(code: "it", name: "Italian",    nativeName: "Italiano"),
        .init(code: "nl", name: "Dutch",      nativeName: "Nederlands"),
        .init(code: "no", name: "Norwegian",  nativeName: "Norsk"),
        .init(code: "da", name: "Danish",     nativeName: "Dansk"),
        .init(code: "fi", name: "Finnish",    nativeName: "Suomi"),
        .init(code: "pl", name: "Polish",     nativeName: "Polski"),
        .init(code: "ru", name: "Russian",    nativeName: "Русский"),
        .init(code: "uk", name: "Ukrainian",  nativeName: "Українська"),
        .init(code: "tr", name: "Turkish",    nativeName: "Türkçe"),
        .init(code: "ar", name: "Arabic",     nativeName: "العربية"),
        .init(code: "hi", name: "Hindi",      nativeName: "हिन्दी"),
        .init(code: "ja", name: "Japanese",   nativeName: "日本語"),
        .init(code: "ko", name: "Korean",     nativeName: "한국어"),
        .init(code: "zh", name: "Chinese",    nativeName: "中文"),
        .init(code: "vi", name: "Vietnamese", nativeName: "Tiếng Việt"),
        .init(code: "id", name: "Indonesian", nativeName: "Bahasa Indonesia"),
        .init(code: "th", name: "Thai",       nativeName: "ไทย"),
        .init(code: "cs", name: "Czech",      nativeName: "Čeština"),
        .init(code: "el", name: "Greek",      nativeName: "Ελληνικά"),
        .init(code: "he", name: "Hebrew",     nativeName: "עברית"),
        .init(code: "ro", name: "Romanian",   nativeName: "Română"),
        .init(code: "hu", name: "Hungarian",  nativeName: "Magyar"),
    ]

    static func find(_ code: String) -> Language? {
        all.first { $0.code == code }
    }
}

/// AppStorage-backed user settings for active model + selected languages.
/// SwiftUI views observe via @AppStorage; non-view code can read directly.
enum UserModelSettings {
    static let activeModelIdKey = "activeModelId"
    static let selectedLanguagesKey = "selectedLanguages"  // CSV: "en,sv,es"

    static var activeModelId: String {
        UserDefaults.standard.string(forKey: activeModelIdKey) ?? ModelRegistry.defaultModelId
    }

    static var selectedLanguageCodes: [String] {
        guard let raw = UserDefaults.standard.string(forKey: selectedLanguagesKey),
              !raw.isEmpty else {
            return ["en"]  // sensible default
        }
        return raw.split(separator: ",").map { String($0) }
    }

    static func setSelectedLanguages(_ codes: [String]) {
        UserDefaults.standard.set(codes.joined(separator: ","), forKey: selectedLanguagesKey)
    }
}
