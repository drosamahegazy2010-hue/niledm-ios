import Foundation

/// The app's own language setting (Settings → Language). Arabic is the default.
enum L10n {
    static let key = "appLanguage"

    static var isEnglish: Bool { UserDefaults.standard.string(forKey: key) == "en" }

    static var locale: Locale { Locale(identifier: isEnglish ? "en" : "ar") }

    /// Also tell iOS, so its own pieces inside the app (share sheet, text menus) match after the next launch.
    static func apply(_ code: String) {
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        Provision.scheduleReminder()
    }
}

/// Picks the Arabic or English text for the current language.
@inline(__always)
func tr(_ ar: String, _ en: String) -> String { L10n.isEnglish ? en : ar }
