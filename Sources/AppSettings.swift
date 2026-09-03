import Foundation

/// Which Stremio web app to load. Defaults to the official web.stremio.com;
/// override in iOS Settings → Stremio → Web URL (e.g. a self-hosted instance).
enum AppSettings {
    static let defaultWebURL = "https://web.stremio.com"
    static let key = "stremioWebURL"

    static var webURL: URL {
        let raw = (UserDefaults.standard.string(forKey: key) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return URL(string: defaultWebURL)! }
        let withScheme = raw.lowercased().hasPrefix("http") ? raw : "https://" + raw
        return URL(string: withScheme) ?? URL(string: defaultWebURL)!
    }
}
