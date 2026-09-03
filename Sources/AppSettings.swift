import Foundation

/// Which Stremio web app to load, plus first-run state. The URL can also be
/// changed later in iOS Settings → Stremio.
enum AppSettings {
    static let defaultWebURL = "https://web.stremio.com"
    static let key = "stremioWebURL"
    static let onboardedKey = "onboarded"
    static let resetKey = "showSetupNextLaunch"

    static var webURL: URL {
        let raw = (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return URL(string: defaultWebURL)! }
        return URL(string: normalize(raw)) ?? URL(string: defaultWebURL)!
    }

    /// Accepts "stremio.example.com", "http://box:8080", or a full URL.
    static func normalize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.lowercased().hasPrefix("http") ? t : "https://" + t
    }

    static func save(webURL: String) {
        UserDefaults.standard.set(normalize(webURL), forKey: key)
        UserDefaults.standard.set(true, forKey: onboardedKey)
    }

    /// Honour the "Show setup on next launch" switch in iOS Settings.
    static func consumeResetIfRequested() {
        let d = UserDefaults.standard
        if d.bool(forKey: resetKey) {
            d.set(false, forKey: resetKey)
            d.set(false, forKey: onboardedKey)
        }
    }
}
