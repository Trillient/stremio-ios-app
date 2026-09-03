import SwiftUI

struct ContentView: View {
    @AppStorage(AppSettings.onboardedKey) private var onboarded = false
    private static var isSelfTest: Bool {
        #if VLC_SELFTEST
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if onboarded || Self.isSelfTest { StremioHostView() } else { OnboardingView { onboarded = true } }
        }
        .onAppear {
            AppSettings.consumeResetIfRequested()
            onboarded = UserDefaults.standard.bool(forKey: AppSettings.onboardedKey)
        }
    }
}

/// The Stremio web UI plus the native player overlay.
struct StremioHostView: View {
    @StateObject private var playback = PlaybackController()
    @StateObject private var model: WebViewModel

    init() {
        NSLog("[STREMIOAPP] StremioHostView init (new PlaybackController)")
        let playback = PlaybackController()
        _playback = StateObject(wrappedValue: playback)
        _model = StateObject(wrappedValue: WebViewModel(
            url: AppSettings.webURL,
            playback: playback
        ))
    }

    var body: some View {
        ZStack {
            // Match the status-bar/home-indicator area to Stremio's own background
            // so it reads as one full-bleed page, not a black letterbox.
            Color(model.chromeColor).ignoresSafeArea()

            WebView(model: model)
                .ignoresSafeArea(edges: .bottom)

            if model.isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(1.4)
            }

            if let message = model.errorMessage {
                RetryView(message: message) { model.reload() }
            }

        }
        #if VLC_SELFTEST
        .onAppear {
            // Replays the real raw stream through the same cookie path as a Play tap.
            guard let raw = ProcessInfo.processInfo.environment["STREMIO_SELFTEST_URL"], let url = URL(string: raw) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                model.playWithCookies(url: url, title: "Self-test stream")
            }
        }
        #endif
        .onAppear {
            if AppSettings.mode == .builtIn {
                ServerScript.ensure(progress: { _ in }) { ok in if ok { NodeServer.shared.startIfNeeded() } }
            }
        }
        .fullScreenCover(item: $playback.stream) { stream in
            VLCPlayerContainer(stream: stream, playback: playback) { playback.stop() }
                .ignoresSafeArea()
                .background(Color.black)
        }
    }
}

private struct RetryView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Can't reach Stremio")
                .font(.headline)
                .foregroundStyle(.white)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}
