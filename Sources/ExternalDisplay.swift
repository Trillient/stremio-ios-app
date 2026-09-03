import UIKit
import Combine

/// TV output. When the phone is AirPlay-mirroring (Apple TV, AirPlay-2 TVs) or on
/// an HDMI adapter, iOS hands the app a second, non-interactive display scene.
/// We render the *decoded* video straight onto it — full quality, any codec —
/// while the phone keeps the controls. This is how VLC for iOS does TV output,
/// and it sidesteps the fact that TVs can't decode torrent MKV/HEVC/AC3 themselves.
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()
    @Published private(set) var view: UIView?
    var isConnected: Bool { view != nil }

    fileprivate func attach(_ v: UIView) { DispatchQueue.main.async { self.view = v } }
    fileprivate func detach() { DispatchQueue.main.async { self.view = nil } }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CastManager.configure()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let c = UISceneConfiguration(name: "External", sessionRole: session.role)
            c.delegateClass = ExternalDisplaySceneDelegate.self
            return c
        }
        return UISceneConfiguration(name: nil, sessionRole: session.role)
    }
}

final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        let w = UIWindow(windowScene: ws)
        let vc = ExternalDisplayViewController()
        w.rootViewController = vc
        w.isHidden = false
        window = w
        NSLog("[STREMIOAPP][tv] external display connected screen=%@ window=%@",
              NSCoder.string(for: ws.screen.bounds.size), NSCoder.string(for: w.bounds.size))
        ExternalDisplay.shared.attach(vc.videoSurface)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        NSLog("[STREMIOAPP][tv] external display disconnected")
        ExternalDisplay.shared.detach()
        window = nil
    }
}


/// Root of the TV window: a branded idle screen, with a full-bleed surface VLC draws into.
final class ExternalDisplayViewController: UIViewController {
    let videoSurface = UIView()
    private let idle = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.055, green: 0.043, blue: 0.12, alpha: 1)
        videoSurface.backgroundColor = .clear
        videoSurface.frame = view.bounds
        videoSurface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoSurface)
        idle.text = "Stremio"
        idle.textColor = UIColor.white.withAlphaComponent(0.35)
        idle.font = .systemFont(ofSize: 48, weight: .semibold)
        idle.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(idle, belowSubview: videoSurface)
        NSLayoutConstraint.activate([idle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     idle.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        NSLog("[STREMIOAPP][tv] external view laid out %@ surface=%@",
              NSCoder.string(for: view.bounds.size), NSCoder.string(for: videoSurface.bounds.size))
    }
}
