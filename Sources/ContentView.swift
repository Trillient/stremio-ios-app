import SwiftUI

struct ContentView: View {
    @AppStorage(AppSettings.onboardedKey) private var onboarded = false

    var body: some View {
        Group {
            if onboarded { StremioHostView() } else { OnboardingView { onboarded = true } }
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
        let playback = PlaybackController()
        _playback = StateObject(wrappedValue: playback)
        _model = StateObject(wrappedValue: WebViewModel(
            url: AppSettings.webURL,
            playback: playback
        ))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

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
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                model.playWithCookies(
                    url: URL(string: ProcessInfo.processInfo.environment["STREMIO_SELFTEST_URL"]
                        ?? "https://your-streaming-server/dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c/1")!,
                    title: "Big Buck Bunny (self-test)"
                )
            }
        }
        #endif
        .fullScreenCover(item: $playback.stream) { stream in
            VLCPlayerContainer(stream: stream) { playback.stop() }
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
