import SwiftUI
import WebKit

/// Owns the WKWebView-driven state so SwiftUI can show loading/error chrome
/// without the web view being torn down on every state change.
final class WebViewModel: ObservableObject {
    @Published var isLoading = true
    @Published var errorMessage: String?

    let url: URL
    let playback: PlaybackController
    fileprivate weak var webView: WKWebView?

    init(url: URL, playback: PlaybackController) {
        self.url = url
        self.playback = playback
    }

    func reload() {
        errorMessage = nil
        isLoading = true
        webView?.load(URLRequest(url: url))
    }

    /// Looks up the site cookies (SSO) and hands the stream to VLC.
    /// Shared by the page interception and the self-test.
    func playWithCookies(url rawURL: URL, title: String) {
        // Stremio's URL builder leaves a dangling '?'; libvlc's HTTP access can
        // mis-handle an empty query, so strip it.
        var s = rawURL.absoluteString
        if s.hasSuffix("?") { s.removeLast() }
        let url = URL(string: s) ?? rawURL
        if playback.stream?.url == url { return }

        guard let webView else {
            playback.play(url: url, title: title, cookieHeader: nil)
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let host = url.host ?? ""
            let matched = cookies.filter { WebViewModel.cookie($0, matchesHost: host) }
            let header = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
            NSLog("[STREMIOAPP] play host=%@ matchedCookies=%d/%d headerLen=%d",
                  host, matched.count, cookies.count, header.count)
            DispatchQueue.main.async {
                self.playback.play(url: url, title: title,
                                   cookieHeader: header.isEmpty ? nil : header)
            }
        }
    }

    private static func cookie(_ cookie: HTTPCookie, matchesHost host: String) -> Bool {
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return host == domain || host.hasSuffix("." + domain)
    }
}

// Injected into every page. Stremio plays through MSE (a blob: <video> source)
// backed by the server's /hlsv2/ ffmpeg transcode, which is slow and stalls.
// We watch fetch/XHR for that transcode request, pull out the RAW file URL it
// wraps (the mediaURL= param), and hand THAT to native VLC — VLC decodes any
// codec directly, skipping the transcode entirely. Plain <video src> (direct,
// non-transcoded content) is caught as a fallback.
private let interceptScript = """
(function () {
  if (window.__vlcHook) return; window.__vlcHook = true;

  function toNative(url, title) {
    try {
      if (!url || url.indexOf('http') !== 0) return;
      window.webkit.messageHandlers.vlc.postMessage(
        JSON.stringify({ url: url, title: title || document.title || 'Stream' })
      );
    } catch (e) {}
  }

  // Stremio's subtitle addons answer .../subtitles/<type>/<id>...json with
  // { subtitles: [{ lang, url }] }. The web player would use them; VLC can't
  // see them, so relay the list to native and load them as playback slaves.
  function isSubs(u) { return typeof u === 'string' && u.indexOf('/subtitles/') !== -1; }
  function postSubs(json) {
    try {
      var list = (json && json.subtitles) || [], items = [];
      for (var i = 0; i < list.length; i++) {
        var t = list[i]; if (!t || !t.url) continue;
        items.push({ lang: t.lang || t.language || '', url: t.url });
      }
      if (items.length) window.webkit.messageHandlers.vlc.postMessage(JSON.stringify({ kind: 'subtitles', items: items }));
    } catch (e) {}
  }

  function isHls(u) {
    return typeof u === 'string' && u.indexOf('/hlsv2/') !== -1 && u.indexOf('.m3u8') !== -1;
  }

  function rawFromHls(u) {
    var key = 'mediaURL=';
    var i = u.indexOf(key);
    if (i === -1) return null;
    var rest = u.substring(i + key.length);
    var amp = rest.indexOf('&');
    if (amp !== -1) rest = rest.substring(0, amp);
    try { return decodeURIComponent(rest); } catch (e) { return rest; }
  }

  // Kill the web player so the server never starts the ffmpeg transcode: pause,
  // mute, and drop any /hlsv2 <video> source (which would keep transcoding).
  function stopWeb() {
    try {
      var vids = document.getElementsByTagName('video');
      for (var i = 0; i < vids.length; i++) {
        var v = vids[i];
        try {
          v.pause(); v.muted = true; v.removeAttribute('autoplay');
          if (v.src && v.src.indexOf('/hlsv2/') !== -1) { v.removeAttribute('src'); v.load(); }
        } catch (_) {}
      }
    } catch (e) {}
  }

  function grab(u) {
    toNative(rawFromHls(u) || u);
    stopWeb(); setTimeout(stopWeb, 300); setTimeout(stopWeb, 1200);
  }

  // fetch: intercept AND block the transcode manifest.
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function (input, init) {
      var u = (typeof input === 'string') ? input : (input && input.url);
      if (isHls(u)) { grab(u); return Promise.reject(new DOMException('handled by native player', 'AbortError')); }
      if (isSubs(u)) {
        return origFetch.apply(this, arguments).then(function (r) {
          try { r.clone().json().then(postSubs).catch(function () {}); } catch (e) {}
          return r;
        });
      }
      return origFetch.apply(this, arguments);
    };
  }

  // XHR: same — mark in open(), then no-op the send() so it never hits the server.
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__hls = isHls(url); this.__subs = isSubs(url); this.__url = url;
    return origOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    if (this.__hls) { grab(this.__url); return; }
    if (this.__subs) {
      this.addEventListener('load', function () { try { postSubs(JSON.parse(this.responseText)); } catch (e) {} });
    }
    return origSend.apply(this, arguments);
  };

  // Fallback for direct (non-transcoded) <video src>.
  var P = HTMLMediaElement.prototype, origPlay = P.play;
  P.play = function () {
    var src = this.currentSrc || this.src;
    if (src && src.indexOf('blob:') !== 0 && src.indexOf('http') === 0) {
      if (src.indexOf('/hlsv2/') !== -1) { grab(src); try { this.removeAttribute('src'); this.load(); } catch (e) {} }
      else { toNative(src); try { this.pause(); this.muted = true; } catch (e) {} }
      return Promise.resolve();
    }
    return origPlay.apply(this, arguments);
  };
})();
"""

private let pinLocalServerScript = """
(function () {
  try {
    var U = 'http://127.0.0.1:11470/';
    var raw = localStorage.getItem('profile');
    if (raw) {
      var p = JSON.parse(raw); p.settings = p.settings || {};
      if (p.settings.streamingServerUrl !== U) { p.settings.streamingServerUrl = U; localStorage.setItem('profile', JSON.stringify(p)); }
    }
  } catch (e) {}
})();
"""

struct WebView: UIViewRepresentable {
    @ObservedObject var model: WebViewModel

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        // .default() is a persistent store, so the SSO cookie and the
        // Stremio login survive app restarts — no re-login on every launch.
        config.websiteDataStore = .default()

        let userScript = WKUserScript(source: interceptScript,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        if AppSettings.mode == .builtIn {
            // Pin Stremio Web's streaming server to the in-app one, even if the
            // account has a different server URL synced into its settings.
            config.userContentController.addUserScript(WKUserScript(source: pinLocalServerScript,
                                                                    injectionTime: .atDocumentStart,
                                                                    forMainFrameOnly: true))
        }
        // Weak proxy: userContentController retains the handler strongly, and the
        // coordinator retains the web view — a direct add() would leak both.
        config.userContentController.add(WeakScriptHandler(context.coordinator), name: "vlc")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black

        model.webView = webView
        webView.load(URLRequest(url: model.url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let model: WebViewModel
        init(_ model: WebViewModel) { self.model = model }

        // MARK: navigation
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            model.isLoading = true
            model.errorMessage = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.isLoading = false
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }
        private func handleFailure(_ error: Error) {
            model.isLoading = false
            if (error as NSError).code == NSURLErrorCancelled { return }
            model.errorMessage = error.localizedDescription
        }

        // MARK: stream interception
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "vlc",
                  let body = message.body as? String,
                  let data = body.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if (obj["kind"] as? String) == "subtitles" {
                let items = (obj["items"] as? [[String: Any]] ?? []).compactMap { d -> PlaybackController.ExternalSubtitle? in
                    guard let u = d["url"] as? String, let url = URL(string: u) else { return nil }
                    return PlaybackController.ExternalSubtitle(lang: d["lang"] as? String ?? "", url: url)
                }
                NSLog("[STREMIOAPP] subtitle addon offered %d tracks", items.count)
                model.playback.addExternalSubtitles(items)
                return
            }
            guard let urlString = obj["url"] as? String, let url = URL(string: urlString) else { return }
            NSLog("[STREMIOAPP] intercepted=%@", urlString)
            let title = (obj["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Stream"
            model.playWithCookies(url: url, title: title)
        }
    }
}

/// Breaks the WKUserContentController → handler → web view retain cycle.
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
