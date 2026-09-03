import SwiftUI
import AVKit
import AVFoundation
import Combine
import MobileVLCKit
import GoogleCast

/// Holds the stream currently requested for native playback. When `stream` is
/// set, ContentView presents the VLC player over the web UI.
final class PlaybackController: ObservableObject {
    struct Stream: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        /// Cookie string copied from the web view so VLC's HTTP access is
        /// authenticated against your SSO the same way the page is.
        let cookieHeader: String?
    }

    struct ExternalSubtitle: Identifiable, Equatable {
        var id: String { url.absoluteString }
        let lang: String
        let url: URL
    }

    @Published var stream: Stream?
    /// Subtitles offered by Stremio's subtitle addons for the current item.
    @Published var externalSubtitles: [ExternalSubtitle] = []

    func play(url: URL, title: String, cookieHeader: String?) {
        stream = Stream(url: url, title: title, cookieHeader: cookieHeader)
    }

    func addExternalSubtitles(_ items: [ExternalSubtitle]) {
        for item in items where !externalSubtitles.contains(item) { externalSubtitles.append(item) }
    }

    func stop() {
        NSLog("[STREMIOAPP] PlaybackController.stop() — dismissing player")
        stream = nil; externalSubtitles = []
    }
}

struct VLCPlayerContainer: UIViewControllerRepresentable {
    let stream: PlaybackController.Stream
    let playback: PlaybackController
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> VLCPlayerViewController {
        VLCPlayerViewController(stream: stream, playback: playback, onClose: onClose)
    }

    func updateUIViewController(_ uiViewController: VLCPlayerViewController, context: Context) {}
}

final class VLCPlayerViewController: UIViewController, VLCMediaPlayerDelegate, UIGestureRecognizerDelegate {
    private let stream: PlaybackController.Stream
    private let playback: PlaybackController
    private let onClose: () -> Void
    private var player: VLCMediaPlayer!
    private var selectedExternalSubtitle: URL?

    private let videoView = UIView()
    private let tapCatcher = UIView()          // above VLC's render view, owns the gestures
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()
    private let controls = PassthroughView()
    private let scrim = UIView()

    private let closeButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let audioButton = UIButton(type: .system)
    private let subsButton = UIButton(type: .system)
    private let aspectButton = UIButton(type: .system)
    private let castButton = UIButton(type: .system)
    private let chromecastButton = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
    private var castCancellables = Set<AnyCancellable>()
    private var currentToken = ""
    private var isCasting = false
    private let tvPlaceholder = UIStackView()
    private var tvCancellable: AnyCancellable?
    private var pendingPosition: Float?
    private let playPauseButton = UIButton(type: .system)
    private let skipBackButton = UIButton(type: .system)
    private let skipForwardButton = UIButton(type: .system)
    private let slider = UISlider()
    private let elapsedLabel = UILabel()
    private let remainingLabel = UILabel()
    private let toastLabel = UILabel()
    private var errorView: UIView?

    private var controlsTimer: Timer?
    private var toastTimer: Timer?
    private var statsTimer: Timer?
    private var isScrubbing = false
    private var hasRenderedFrame = false
    private var closed = false

    private var zoom: CGFloat = 1                // 1 = fit; >1 zoomed/filled
    private var filled = false
    private static let vlcLogger = VLCLogBridge()

    init(stream: PlaybackController.Stream, playback: PlaybackController, onClose: @escaping () -> Void) {
        self.stream = stream
        self.playback = playback
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSLog("[STREMIOAPP] player VC deinit"); stopPlayerAsync() }

    private static func symbol(_ name: String, size: CGFloat = 22) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: size))
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true
        setupVideoView()
        setupGestures()
        setupSpinner()
        setupControls()
        startPlayback()
    }

    // MARK: - Layout

    private func setupVideoView() {
        videoView.backgroundColor = .black
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)

        let icon = UIImageView(image: UIImage(systemName: "tv", withConfiguration: UIImage.SymbolConfiguration(pointSize: 44)))
        icon.tintColor = UIColor.white.withAlphaComponent(0.9)
        let label = UILabel()
        label.text = "Playing on your TV"
        label.textColor = .white
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        let sub = UILabel()
        sub.text = "Use the controls here."
        sub.textColor = UIColor.white.withAlphaComponent(0.6)
        sub.font = .systemFont(ofSize: 14)
        tvPlaceholder.axis = .vertical
        tvPlaceholder.alignment = .center
        tvPlaceholder.spacing = 8
        [icon, label, sub].forEach { tvPlaceholder.addArrangedSubview($0) }
        tvPlaceholder.isHidden = true
        tvPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tvPlaceholder)
        NSLayoutConstraint.activate([
            tvPlaceholder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tvPlaceholder.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -90),
        ])

        tapCatcher.frame = view.bounds
        tapCatcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        tapCatcher.backgroundColor = .clear
        view.addSubview(tapCatcher)
    }

    private func setupGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(didDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinch))
        for g in [tap, doubleTap] as [UIGestureRecognizer] { g.delegate = self; tapCatcher.addGestureRecognizer(g) }
        pinch.delegate = self
        tapCatcher.addGestureRecognizer(pinch)
    }

    private func setupSpinner() {
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)

        statusLabel.text = "Connecting to stream\u{2026}"
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        statusLabel.font = .systemFont(ofSize: 14)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toastLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 8
        toastLabel.layer.masksToBounds = true
        toastLabel.alpha = 0
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toastLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 72),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            toastLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            toastLabel.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    private func setupControls() {
        controls.frame = view.bounds
        controls.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controls)

        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        scrim.frame = controls.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.isUserInteractionEnabled = false
        controls.addSubview(scrim)

        configureIcon(closeButton, "xmark", action: #selector(didTapClose))
        configureIcon(audioButton, "waveform", action: #selector(showAudioMenu))
        configureIcon(subsButton, "captions.bubble", action: #selector(showSubtitleMenu))
        configureIcon(aspectButton, "rectangle.arrowtriangle.2.inward", action: #selector(didTapAspect))
        configureIcon(castButton, "airplayvideo", action: #selector(didTapCast))
        configureIcon(playPauseButton, "pause.fill", action: #selector(didTapPlayPause), size: 48)
        configureIcon(skipBackButton, "gobackward.10", action: #selector(didTapSkipBack), size: 32)
        configureIcon(skipForwardButton, "goforward.10", action: #selector(didTapSkipForward), size: 32)
        for b in [closeButton, playPauseButton, skipBackButton, skipForwardButton] { controls.addSubview(b) }

        titleLabel.text = stream.title
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(titleLabel)

        chromecastButton.tintColor = .white
        chromecastButton.translatesAutoresizingMaskIntoConstraints = false
        chromecastButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let topRight = UIStackView(arrangedSubviews: [audioButton, subsButton, aspectButton, chromecastButton, castButton])
        topRight.axis = .horizontal
        topRight.spacing = 16
        topRight.translatesAutoresizingMaskIntoConstraints = false
        controls.addSubview(topRight)

        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .white
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(scrubStart), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubEnd), for: [.touchUpInside, .touchUpOutside])
        controls.addSubview(slider)

        for label in [elapsedLabel, remainingLabel] {
            label.textColor = .white
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            label.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview(label)
        }
        remainingLabel.textAlignment = .right

        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            closeButton.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topRight.leadingAnchor, constant: -12),
            topRight.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            topRight.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),

            playPauseButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            skipBackButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            skipBackButton.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -44),
            skipForwardButton.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            skipForwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 44),

            elapsedLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 16),
            elapsedLabel.bottomAnchor.constraint(equalTo: g.bottomAnchor, constant: -12),
            remainingLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -16),
            remainingLabel.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: elapsedLabel.trailingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: remainingLabel.leadingAnchor, constant: -8),
            slider.centerYAnchor.constraint(equalTo: elapsedLabel.centerYAnchor),
        ])
    }

    private func configureIcon(_ b: UIButton, _ name: String, action: Selector, size: CGFloat = 22) {
        b.setImage(Self.symbol(name, size: size), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: action, for: .touchUpInside)
    }

    // MARK: - Playback

    private func startPlayback() {
        VLCLibrary.shared().loggers = [Self.vlcLogger]
        player = VLCMediaPlayer()

        // VLC can't carry the SSO cookie itself; the loopback proxy adds it.
        let playURL = StreamProxy.shared.register(origin: stream.url, cookie: stream.cookieHeader)
        currentToken = StreamProxy.shared.lastToken
        let media = VLCMedia(url: playURL)
        media.addOption(":network-caching=4000")
        media.addOption(":avcodec-skiploopfilter=3")
        media.addOption(":avcodec-threads=0")
        NSLog("[STREMIOAPP] VLC opening %@ -> %@ cookie=%@", playURL.absoluteString,
              stream.url.absoluteString, (stream.cookieHeader?.isEmpty == false) ? "yes" : "no")
        player.media = media
        player.delegate = self
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        applyRenderTarget(ExternalDisplay.shared.view)
        tvCancellable = ExternalDisplay.shared.$view
            .receive(on: DispatchQueue.main)
            .sink { [weak self] v in self?.applyRenderTarget(v) }
        player.play()
        startStatsPolling()
        scheduleControlsHide()
        wireCast()
    }

    // MARK: - Chromecast

    private func wireCast() {
        let cast = CastManager.shared
        cast.onSessionStarted = { [weak self] in self?.castSessionStarted() }
        cast.onSessionEnded = { [weak self] pos in self?.castSessionEnded(at: pos) }
        cast.$remotePosition.combineLatest(cast.$remoteDuration)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] pos, dur in
                guard let self, self.isCasting, dur > 0, !self.isScrubbing else { return }
                self.slider.value = Float(pos / dur)
                self.elapsedLabel.text = Self.clock(pos)
                self.remainingLabel.text = "-" + Self.clock(max(0, dur - pos))
            }.store(in: &castCancellables)
        if cast.isConnected { castSessionStarted() }
        #if VLC_SELFTEST
        if ProcessInfo.processInfo.environment["STREMIO_SELFTEST_CAST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { _ = CastManager.shared.startSessionWithFirstDevice() }
        }
        #endif
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded()); return s >= 3600 ? String(format: "%d:%02d:%02d", s/3600, s%3600/60, s%60) : String(format: "%02d:%02d", s/60, s%60)
    }

    /// Chromecast decodes the file itself, so it must be a format it supports.
    private func castableContentType() -> String? {
        let ct = (StreamProxy.shared.contentType(forToken: currentToken) ?? "").lowercased()
        let path = stream.url.path.lowercased()
        if ct.contains("mpegurl") || path.hasSuffix(".m3u8") { return "application/x-mpegURL" }
        if ct.contains("mp4") || ct.contains("m4v") || path.hasSuffix(".mp4") || path.hasSuffix(".m4v") { return "video/mp4" }
        if ct.contains("webm") || path.hasSuffix(".webm") { return "video/webm" }
        if ct.contains("quicktime") || path.hasSuffix(".mov") { return "video/mp4" }
        return nil
    }

    private func castSessionStarted() {
        guard let player else { return }
        guard let contentType = castableContentType(),
              let url = StreamProxy.shared.lanURL(forToken: currentToken, hls: contentType.contains("mpegURL")) else {
            let name = CastManager.shared.deviceName ?? "the Chromecast"
            NSLog("[STREMIOAPP][cast] not castable: %@", StreamProxy.shared.contentType(forToken: currentToken) ?? "unknown type")
            let a = UIAlertController(title: "Can\u{2019}t cast this file",
                message: "\(name) can only play MP4/H.264, WebM and HLS streams, and this one is a format it can\u{2019}t decode (usually MKV / x265 / AC3). Use AirPlay or an HDMI adapter instead \u{2014} the phone decodes it and the TV shows it.",
                preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
            CastManager.shared.endSession()
            return
        }
        let seconds = Double(player.position) * (Double(player.media?.length.intValue ?? 0) / 1000)
        player.pause()
        isCasting = true
        setTVPlaceholder(text: "Casting to \(CastManager.shared.deviceName ?? "TV")", visible: true)
        CastManager.shared.load(url: url, contentType: contentType, title: stream.title, startAt: seconds)
    }

    private func castSessionEnded(at remoteSeconds: TimeInterval) {
        guard isCasting, let player else { return }
        isCasting = false
        setTVPlaceholder(text: "Playing on your TV", visible: ExternalDisplay.shared.isConnected)
        let len = Double(player.media?.length.intValue ?? 0) / 1000
        if len > 0 { player.position = Float(remoteSeconds / len) }
        player.play()
        NSLog("[STREMIOAPP][cast] back to local at %.0fs", remoteSeconds)
    }

    private func setTVPlaceholder(text: String, visible: Bool) {
        (tvPlaceholder.arrangedSubviews[1] as? UILabel)?.text = text
        tvPlaceholder.isHidden = !visible
    }

    /// Never call VLCMediaPlayer.stop() on the main thread — on a stuck network
    /// input it blocks, which is what froze "close" mid-buffer. Detach it.
    private func stopPlayerAsync() {
        tvCancellable = nil
        castCancellables.removeAll()
        CastManager.shared.onSessionStarted = nil
        CastManager.shared.onSessionEnded = nil
        statsTimer?.invalidate(); statsTimer = nil
        controlsTimer?.invalidate(); controlsTimer = nil
        guard let p = player else { return }
        player = nil
        DispatchQueue.global(qos: .userInitiated).async { p.stop() }
    }

    /// Route VLC's output to the TV when one is attached, back to the phone when not.
    /// libvlc won't re-parent a live video output, so if we're already playing we
    /// restart on the new surface and seek back to where we were (~1s blip).
    private func applyRenderTarget(_ tv: UIView?) {
        guard let player else { return }
        let target: UIView = tv ?? videoView
        tvPlaceholder.isHidden = (tv == nil)
        if tv != nil { videoView.transform = .identity; zoom = 1; filled = false }
        let live = hasRenderedFrame && (player.isPlaying || player.state == .paused || player.state == .buffering)
        if live, let media = player.media {
            let pos = player.position
            player.stop()
            player.drawable = target
            player.media = media
            pendingPosition = pos > 0.001 ? pos : nil
            player.play()
            NSLog("[STREMIOAPP][tv] restarted on %@ at %.3f", tv == nil ? "phone" : "external display", pos)
        } else {
            player.drawable = target
            NSLog("[STREMIOAPP][tv] rendering on %@", tv == nil ? "phone" : "external display")
        }
    }

    @objc private func didTapCast() {
        let onTV = ExternalDisplay.shared.isConnected
        let title = onTV ? "Playing on your TV" : "Play on a TV"
        let msg = onTV
            ? "The video is on the connected display. Disconnect AirPlay / the HDMI adapter to bring it back to the phone."
            : "Plays any file on any TV \u{2014} the phone decodes it and sends the picture:\n\n1. Open Control Center\n2. Tap Screen Mirroring\n3. Pick your Apple TV or AirPlay TV\n\nThe video fills the TV (not a mirrored phone screen) and you keep the controls here. A USB-C/Lightning-to-HDMI adapter works the same way.\n\nFor a Chromecast, use the Cast button \u{2014} works for MP4/H.264 streams."
        let sheet = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.scheduleControlsHide() })
        present(sheet, animated: true)
        controlsTimer?.invalidate()
    }

    // MARK: - Actions

    @objc private func didTapClose() {
        guard !closed else { return }
        closed = true
        stopPlayerAsync()      // detached, non-blocking
        onClose()              // dismiss immediately
    }

    @objc private func didTapPlayPause() {
        guard let player else { return }
        if isCasting {
            let playing = CastManager.shared.remotePlaying
            playing ? CastManager.shared.pause() : CastManager.shared.play()
            playPauseButton.setImage(Self.symbol(playing ? "play.fill" : "pause.fill", size: 48), for: .normal)
            scheduleControlsHide(); return
        }
        if player.isPlaying {
            player.pause()
            playPauseButton.setImage(Self.symbol("play.fill", size: 48), for: .normal)
        } else {
            player.play()
            playPauseButton.setImage(Self.symbol("pause.fill", size: 48), for: .normal)
        }
        scheduleControlsHide()
    }

    @objc private func didTapSkipBack() { isCasting ? CastManager.shared.skip(by: -10) : player?.jumpBackward(10); scheduleControlsHide() }
    @objc private func didTapSkipForward() { isCasting ? CastManager.shared.skip(by: 10) : player?.jumpForward(10); scheduleControlsHide() }
    @objc private func scrubStart() { isScrubbing = true }
    @objc private func scrubEnd() {
        if isCasting { CastManager.shared.seek(to: Double(slider.value) * CastManager.shared.remoteDuration) }
        else { player?.position = slider.value }
        isScrubbing = false; scheduleControlsHide()
    }

    // MARK: - Audio / subtitle tracks

    private func trackList(indexes: [Any]?, names: [Any]?) -> [(Int32, String)] {
        guard let indexes, let names, indexes.count == names.count else { return [] }
        return zip(indexes, names).compactMap { idx, nm in
            guard let i = (idx as? NSNumber)?.int32Value, let n = nm as? String else { return nil }
            return (i, n)
        }
    }

    @objc private func showAudioMenu() {
        guard let player else { return }
        let tracks = trackList(indexes: player.audioTrackIndexes, names: player.audioTrackNames)
        presentTrackSheet(title: "Audio", tracks: tracks, current: player.currentAudioTrackIndex, from: audioButton) {
            player.currentAudioTrackIndex = $0
        }
    }

    @objc private func showSubtitleMenu() {
        guard let player else { return }
        let embedded = trackList(indexes: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames)
        let online = playback.externalSubtitles
        let sheet = UIAlertController(title: "Subtitles",
                                      message: (embedded.count <= 1 && online.isEmpty) ? "No subtitles for this stream" : nil,
                                      preferredStyle: .actionSheet)
        // Embedded tracks (VLC lists "Disable" first with index -1).
        for (index, name) in embedded {
            let active = selectedExternalSubtitle == nil && index == player.currentVideoSubTitleIndex
            let label = index == -1 ? "Off" : name
            sheet.addAction(UIAlertAction(title: (active ? "\u{2713} " : "") + label, style: .default) { _ in
                self.selectedExternalSubtitle = nil
                player.currentVideoSubTitleIndex = index
                self.scheduleControlsHide()
            })
        }
        // Online tracks from Stremio's subtitle addons, one per language.
        var seenLang = Set<String>()
        for sub in online where seenLang.insert(sub.lang.lowercased()).inserted {
            let active = selectedExternalSubtitle == sub.url
            sheet.addAction(UIAlertAction(title: (active ? "\u{2713} " : "") + Self.languageName(sub.lang) + " (online)", style: .default) { _ in
                // VLC fetches the file itself; enforce=true makes it the active track.
                player.addPlaybackSlave(sub.url, type: .subtitle, enforce: true)
                self.selectedExternalSubtitle = sub.url
                self.flashToast(Self.languageName(sub.lang))
                self.scheduleControlsHide()
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController { pop.sourceView = subsButton; pop.sourceRect = subsButton.bounds }
        present(sheet, animated: true)
        controlsTimer?.invalidate()
    }

    private static func languageName(_ code: String) -> String {
        let c = code.trimmingCharacters(in: .whitespaces)
        if c.isEmpty { return "Unknown" }
        if c.count <= 3, let name = Locale.current.localizedString(forLanguageCode: c.lowercased()) { return name.capitalized }
        return c.capitalized
    }

    private func presentTrackSheet(title: String, tracks: [(Int32, String)], current: Int32,
                                   from source: UIView, apply: @escaping (Int32) -> Void) {
        let sheet = UIAlertController(title: title, message: tracks.isEmpty ? "No tracks available" : nil, preferredStyle: .actionSheet)
        for (index, name) in tracks {
            let mark = index == current ? "\u{2713} " : ""
            sheet.addAction(UIAlertAction(title: mark + name, style: .default) { _ in apply(index); self.scheduleControlsHide() })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let pop = sheet.popoverPresentationController { pop.sourceView = source; pop.sourceRect = source.bounds }
        present(sheet, animated: true)
        controlsTimer?.invalidate()   // keep controls up while the menu is open
    }

    // MARK: - Zoom / aspect

    @objc private func didTapAspect() {
        filled.toggle()
        applyZoom(fillIfPossible: filled, animated: true)
        flashToast(filled ? "Fill" : "Fit")
        scheduleControlsHide()
    }

    @objc private func didDoubleTap() {
        filled.toggle()
        applyZoom(fillIfPossible: filled, animated: true)
        flashToast(filled ? "Fill" : "Fit")
    }

    @objc private func didPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .changed:
            let z = min(max(zoom * g.scale, 1), 4)
            videoView.transform = CGAffineTransform(scaleX: z, y: z)
        case .ended, .cancelled:
            zoom = min(max(zoom * g.scale, 1), 4)
            filled = zoom > 1.01
            flashToast(zoom <= 1.01 ? "Fit" : String(format: "%.0f%%", Double(zoom) * 100))
        default: break
        }
    }

    /// Fit = 1x (VLC letterboxes). Fill = scale the whole render view until the
    /// video edges reach the screen, cropping the letterbox bars.
    private func applyZoom(fillIfPossible: Bool, animated: Bool) {
        var target: CGFloat = 1
        if fillIfPossible {
            let vs = player?.videoSize ?? .zero
            let b = view.bounds.size
            if vs.width > 0, vs.height > 0, b.width > 0, b.height > 0 {
                let fit = min(b.width / vs.width, b.height / vs.height)
                let fill = max(b.width / vs.width, b.height / vs.height)
                if fit > 0 { target = fill / fit }
            } else {
                target = max(b.width, b.height) / min(b.width, b.height)  // best-effort before videoSize known
            }
        }
        zoom = target
        let apply = { self.videoView.transform = CGAffineTransform(scaleX: target, y: target) }
        animated ? UIView.animate(withDuration: 0.25, animations: apply) : apply()
    }

    private func flashToast(_ text: String) {
        toastLabel.text = "  \(text)  "
        toastTimer?.invalidate()
        UIView.animate(withDuration: 0.15) { self.toastLabel.alpha = 1 }
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            UIView.animate(withDuration: 0.3) { self?.toastLabel.alpha = 0 }
        }
    }

    // MARK: - Controls visibility

    @objc private func toggleControls() { setControls(hidden: controls.alpha > 0) }

    private func setControls(hidden: Bool) {
        UIView.animate(withDuration: 0.25) { self.controls.alpha = hidden ? 0 : 1 }
        if !hidden { scheduleControlsHide() }
    }

    private func scheduleControlsHide() {
        #if VLC_SELFTEST
        return
        #endif
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 4.5, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.player?.isPlaying == true { self.setControls(hidden: true) } else { self.scheduleControlsHide() }
        }
    }

    // MARK: - Buffering status

    private func statsURL() -> URL? {
        let parts = stream.url.pathComponents.filter { $0 != "/" }
        guard let hash = parts.first, hash.count == 40, let host = stream.url.host else { return nil }
        return URL(string: "https://\(host)/\(hash)/stats.json")
    }

    private func startStatsPolling() {
        guard let url = statsURL() else { statusLabel.isHidden = true; return }
        statusLabel.isHidden = false
        let started = Date()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.hasRenderedFrame else { return }
            var req = URLRequest(url: url)
            if let cookie = self.stream.cookieHeader { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
            URLSession.shared.dataTask(with: req) { data, _, _ in
                guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                let peers = json["peers"] as? Int ?? 0
                let speed = (json["downloadSpeed"] as? Double ?? 0) / 1_000_000
                let ready = (json["downloaded"] as? Double ?? 0) / 1_000_000
                let waited = Int(Date().timeIntervalSince(started))
                let text: String
                if peers == 0 && waited > 30 {
                    text = "No sources found after \(waited)s. This stream may be dead \u{2014} try another one."
                } else if peers == 0 {
                    text = "Finding sources\u{2026}"
                } else {
                    text = String(format: "Buffering from %d sources \u{00B7} %.1f MB/s \u{00B7} %.0f MB ready", peers, speed, ready)
                }
                DispatchQueue.main.async { self.statusLabel.text = text }
            }.resume()
        }
    }

    private func stopStatsPolling() { statsTimer?.invalidate(); statsTimer = nil; statusLabel.isHidden = true }

    // MARK: - Error / retry

    private func showError(_ message: String) {
        stopStatsPolling()
        spinner.stopAnimating()
        guard errorView == nil else { return }
        let title = UILabel()
        title.text = "Stream didn\u{2019}t start"
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .white
        title.textAlignment = .center
        let body = UILabel()
        body.text = message
        body.numberOfLines = 0
        body.textAlignment = .center
        body.textColor = UIColor.white.withAlphaComponent(0.8)
        body.font = .systemFont(ofSize: 15)
        let retry = UIButton(type: .system)
        retry.setTitle("Try again", for: .normal)
        retry.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        retry.tintColor = .black
        retry.backgroundColor = .white
        retry.layer.cornerRadius = 10
        retry.contentEdgeInsets = UIEdgeInsets(top: 10, left: 22, bottom: 10, right: 22)
        retry.addTarget(self, action: #selector(didTapRetry), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, body, retry])
        stack.axis = .vertical; stack.spacing = 14; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
        errorView = stack
        setControls(hidden: false)
    }

    @objc private func didTapRetry() {
        errorView?.removeFromSuperview(); errorView = nil
        hasRenderedFrame = false
        spinner.startAnimating()
        stopPlayerAsync()
        startPlayback()
    }

    // MARK: - VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let player else { return }
        NSLog("[STREMIOAPP] VLC state=%ld isPlaying=%d", player.state.rawValue, player.isPlaying)
        switch player.state {
        case .opening: if !hasRenderedFrame { spinner.startAnimating() }
        case .error:
            showError("This torrent has too few sources right now, or it\u{2019}s still finding them. Give it a moment and try again, or pick a stream with more seeders.")
        case .ended, .stopped: spinner.stopAnimating()
        default: break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard let player else { return }
        if let p = pendingPosition, player.isPlaying {
            pendingPosition = nil
            player.position = p
            NSLog("[STREMIOAPP][tv] resumed at %.3f", p)
        }
        if !hasRenderedFrame {
            hasRenderedFrame = true
            spinner.stopAnimating()
            NSLog("[STREMIOAPP] first frame at %@", player.time.stringValue)
            stopStatsPolling()
            scheduleControlsHide()
            #if VLC_SELFTEST
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, let player = self.player else { return }
                let subs = self.trackList(indexes: player.videoSubTitlesIndexes, names: player.videoSubTitlesNames)
                if let t = subs.first(where: { $0.0 != -1 }) {
                    player.currentVideoSubTitleIndex = t.0
                    player.position = 0.08
                    NSLog("[STREMIOAPP] selftest picked subtitle %d '%@' of %d", t.0, t.1, subs.count)
                }
            }
            #endif
        }
        guard !isScrubbing else { return }
        slider.value = player.position
        elapsedLabel.text = player.time.stringValue
        if let remaining = player.remainingTime?.stringValue { remainingLabel.text = remaining }
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(touch.view is UIControl)
    }
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

/// Overlay that ignores touches on its own empty areas so the underlying
/// tap-to-toggle gesture still fires; real controls (buttons/slider) still work.
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Forwards libvlc's own log (HTTP status, demux/decoder errors) into the
/// unified log so failures are diagnosable from `log show`.
final class VLCLogBridge: NSObject, VLCLogging {
    var level: VLCLogLevel = .debug
    func handleMessage(_ message: String, logLevel: VLCLogLevel, context: VLCLogContext?) {
        let m = message.lowercased()
        let keep = (logLevel == .error || logLevel == .warning || m.contains("http")
            || m.contains("using demux") || m.contains("decoder") || m.contains("codec")
            || m.contains("videotoolbox")) && !m.contains("too late") && !m.contains("displayed late")
        if keep && message.count < 400 { NSLog("[STREMIOAPP][vlc] %@", message) }
    }
}
