import Foundation
import GoogleCast

/// Google Cast (Chromecast / Google TV / Cast-enabled TVs & soundbars).
///
/// Casting hands the TV a URL to fetch and decode itself, so it only works for
/// formats the Chromecast can decode (MP4/H.264/AAC, HLS, WebM). Torrent MKVs
/// with x265/AC3/DTS can't be cast directly — they need a transcoding server
/// (own-server mode) or AirPlay/HDMI output (which the phone decodes).
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()

    @Published private(set) var deviceName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var remotePosition: TimeInterval = 0
    @Published private(set) var remoteDuration: TimeInterval = 0
    @Published private(set) var remotePlaying = false

    var onSessionStarted: (() -> Void)?
    var onSessionEnded: ((TimeInterval) -> Void)?

    private var context: GCKCastContext { GCKCastContext.sharedInstance() }
    private var client: GCKRemoteMediaClient? { context.sessionManager.currentCastSession?.remoteMediaClient }

    /// Call once at launch.
    static func configure() {
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        options.startDiscoveryAfterFirstTapOnCastButton = false
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().sessionManager.add(shared)
        GCKCastContext.sharedInstance().discoveryManager.add(shared)
        NSLog("[STREMIOAPP][cast] configured; discovery started")
    }

    func load(url: URL, contentType: String, title: String, startAt seconds: TimeInterval) {
        guard let client else { NSLog("[STREMIOAPP][cast] no session to load into"); return }
        let meta = GCKMediaMetadata(metadataType: .movie)
        meta.setString(title, forKey: kGCKMetadataKeyTitle)
        let info = GCKMediaInformationBuilder(contentURL: url)
        info.streamType = .buffered
        info.contentType = contentType
        info.metadata = meta
        let req = GCKMediaLoadRequestDataBuilder()
        req.mediaInformation = info.build()
        req.autoplay = NSNumber(value: true)
        req.startTime = seconds
        client.add(self)
        client.loadMedia(with: req.build())
        NSLog("[STREMIOAPP][cast] load %@ (%@) at %.0fs", url.absoluteString, contentType, seconds)
    }

    func play() { client?.play() }
    func pause() { client?.pause() }
    func seek(to seconds: TimeInterval) {
        let o = GCKMediaSeekOptions(); o.interval = seconds; client?.seek(with: o)
    }
    func skip(by delta: TimeInterval) {
        let o = GCKMediaSeekOptions(); o.interval = delta; o.relative = true; client?.seek(with: o)
    }
    func endSession() { _ = context.sessionManager.endSessionAndStopCasting(true) }

    /// Test hook: connect to the first discovered device.
    func startSessionWithFirstDevice() -> Bool {
        let dm = context.discoveryManager
        guard dm.deviceCount > 0 else { NSLog("[STREMIOAPP][cast] no devices discovered yet"); return false }
        var device = dm.device(at: 0)
        for i in 0..<dm.deviceCount {
            let d = dm.device(at: i)
            if (d.friendlyName ?? "").localizedCaseInsensitiveContains("chromecast") || (d.modelName ?? "").localizedCaseInsensitiveContains("chromecast") { device = d; break }
        }
        NSLog("[STREMIOAPP][cast] starting session with %@", device.friendlyName ?? "?")
        return context.sessionManager.startSession(with: device)
    }
}

extension CastManager: GCKSessionManagerListener, GCKRemoteMediaClientListener, GCKDiscoveryManagerListener {
    func didUpdateDeviceList() {
        let dm = GCKCastContext.sharedInstance().discoveryManager
        var names: [String] = []
        for i in 0..<dm.deviceCount { names.append(dm.device(at: i).friendlyName ?? "?") }
        NSLog("[STREMIOAPP][cast] devices: %@", names.joined(separator: ", "))
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        deviceName = session.device.friendlyName
        isConnected = true
        NSLog("[STREMIOAPP][cast] session started with %@", deviceName ?? "?")
        onSessionStarted?()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        NSLog("[STREMIOAPP][cast] session failed: %@", error.localizedDescription)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        NSLog("[STREMIOAPP][cast] session ended %@", error?.localizedDescription ?? "")
        let pos = remotePosition
        isConnected = false
        deviceName = nil
        remotePlaying = false
        onSessionEnded?(pos)
    }

    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard let s = mediaStatus else { return }
        remotePosition = s.streamPosition
        remoteDuration = s.mediaInformation?.streamDuration ?? 0
        remotePlaying = s.playerState == .playing
        let state: String
        switch s.playerState {
        case .playing: state = "playing"; case .paused: state = "paused"
        case .buffering: state = "buffering"; case .loading: state = "loading"
        case .idle: state = "idle(\(s.idleReason.rawValue))"; default: state = "unknown"
        }
        NSLog("[STREMIOAPP][cast] remote %@ %.1f/%.1f", state, remotePosition, remoteDuration)
    }
}
