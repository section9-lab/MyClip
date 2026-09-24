import Foundation

/// The languages MyClip ships. The interface follows the system language when it is one of these, and English when it
/// is not; macOS would otherwise fall back to the development region, which is Chinese.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case chinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"

    public var id: String { rawValue }

    /// The language's own name, the way macOS lists languages.
    public var nativeName: String {
        switch self {
        case .chinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        case .spanish: "Español"
        case .french: "Français"
        case .german: "Deutsch"
        }
    }

    /// The language in use, which is the first system preference MyClip ships, or English.
    public static var current: AppLanguage {
        Locale.preferredLanguages.lazy.compactMap(AppLanguage.init(matching:)).first ?? .english
    }

    /// Pins the interface to English when no preferred language is one MyClip ships. Call before the first localized
    /// string is read, otherwise the bundle has already resolved its language for this launch.
    public static func applyAtLaunch(defaults: UserDefaults = .standard) {
        guard Locale.preferredLanguages.allSatisfy({ AppLanguage(matching: $0) == nil }) else { return }
        defaults.set([AppLanguage.english.rawValue], forKey: languagesKey)
    }

    /// Stores the chosen language the way System Settings' per-app language does. Takes effect on the next launch.
    public static func select(_ language: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set([language.rawValue], forKey: languagesKey)
    }

    private static let languagesKey = "AppleLanguages"

    /// Matches a BCP 47 identifier such as `ja-JP` or `zh-Hant-TW`. Only Simplified Chinese ships, so every Chinese
    /// variant maps to it rather than falling through to English.
    init?(matching identifier: String) {
        switch Locale(identifier: identifier).language.languageCode?.identifier {
        case "zh": self = .chinese
        case "en": self = .english
        case "ja": self = .japanese
        case "ko": self = .korean
        case "es": self = .spanish
        case "fr": self = .french
        case "de": self = .german
        default: return nil
        }
    }
}
