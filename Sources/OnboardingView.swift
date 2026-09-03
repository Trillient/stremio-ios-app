import SwiftUI

/// First-run setup. Torrent playback needs a Stremio streaming server, which the
/// official web.stremio.com does not provide — so ask up front instead of
/// dropping people onto a page that can't stream.
struct OnboardingView: View {
    let onDone: () -> Void

    private enum Choice { case selfHosted, official }
    @State private var choice: Choice? = nil
    @State private var serverURL: String = UserDefaults.standard.string(forKey: AppSettings.key) ?? ""
    @FocusState private var urlFocused: Bool

    private let purple = Color(red: 123 / 255, green: 91 / 255, blue: 245 / 255)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.08, green: 0.07, blue: 0.16), .black],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    logo.padding(.top, 24)

                    Text("Stremio for iPhone")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Where should the app connect?")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.9))

                    Text("Playing torrents needs a **Stremio streaming server**. The official website doesn\u{2019}t include one, so most people either run their own Stremio instance or use a debrid service.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))

                    optionCard(
                        selected: choice == .selfHosted,
                        title: "I run my own Stremio",
                        detail: "Enter your instance (with its streaming server). Everything plays, including torrents.",
                        icon: "server.rack"
                    ) { choice = .selfHosted; urlFocused = true }

                    if choice == .selfHosted {
                        TextField("https://stremio.yourdomain.com", text: $serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .focused($urlFocused)
                            .padding(14)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }

                    optionCard(
                        selected: choice == .official,
                        title: "Use the official web.stremio.com",
                        detail: "Torrents won\u{2019}t play unless you add a debrid addon (Real-Debrid, AllDebrid, Premiumize) or set a streaming server URL in Stremio\u{2019}s settings.",
                        icon: "globe"
                    ) { choice = .official; urlFocused = false }

                    Button(action: finish) {
                        Text("Continue")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(canContinue ? purple : purple.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(.white)
                    }
                    .disabled(!canContinue)
                    .padding(.top, 6)

                    Text("You can change this later in iOS Settings \u{2192} Stremio.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var canContinue: Bool {
        switch choice {
        case .selfHosted: return !serverURL.trimmingCharacters(in: .whitespaces).isEmpty
        case .official: return true
        case nil: return false
        }
    }

    private func finish() {
        AppSettings.save(webURL: choice == .official ? AppSettings.defaultWebURL : serverURL)
        onDone()
    }

    private var logo: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18).fill(purple).frame(width: 72, height: 72)
            Image(systemName: "play.fill").font(.system(size: 32, weight: .bold)).foregroundStyle(.white).offset(x: 3)
        }
    }

    private func optionCard(selected: Bool, title: String, detail: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon).font(.system(size: 22)).foregroundStyle(purple).frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline).foregroundStyle(.white)
                    Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? purple : .white.opacity(0.3))
            }
            .padding(16)
            .background(Color.white.opacity(selected ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(selected ? purple : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }
}
