import Foundation

/// Which Stremio web app to load, plus first-run state. The URL can also be
/// changed later in iOS Settings → Stremio.
enum AppSettings {
    static let defaultWebURL = "https://web.stremio.com"
    static let key = "stremioWebURL"
    static let onboardedKey = "onboarded"
    static let resetKey = "showSetupNextLaunch"
    static let modeKey = "streamMode"

    enum Mode: String { case builtIn = "builtin", ownServer = "own" }
    /// Built-in = official web UI + the in-app streaming server on 127.0.0.1:11470.
    static var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "") ?? .builtIn
    }

    static var webURL: URL {
        // Built-in mode: the official web app, served from localhost by our proxy so
        // it may talk to the in-app server (an https page can't call http://127.0.0.1).
        if mode == .builtIn { return StreamProxy.shared.mirrorBaseURL }
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

    static func save(mode: Mode, webURL: String) {
        let d = UserDefaults.standard
        d.set(mode.rawValue, forKey: modeKey)
        d.set(mode == .builtIn ? defaultWebURL : normalize(webURL), forKey: key)
        d.set(true, forKey: onboardedKey)
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
