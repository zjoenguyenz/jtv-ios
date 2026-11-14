import SwiftUI
import AVKit
import WebKit

// MARK: - Native player surface

/// AVPlayerViewController wrapper: plays a URL with custom HTTP headers,
/// seeks to a start position and reports progress every 5 seconds.
struct VideoPlayerSurface: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]
    let startPosition: Double
    var startViaProxy: Bool = false
    var onProgress: (Double, Double) -> Void
    var onExit: (Double, Double) -> Void
    var onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onExit: onExit)
    }

    func makeUIViewController(context: Context) -> PlayerHostViewController {
        // Playback may rotate; the rest of the app may not. The
        // surface owns the lock: opened here, restored in dismantle
        // (the one callback that only runs when the player screen
        // is really gone — appearance callbacks also fire when the
        // presented player merely covers the screen, and restoring
        // portrait from one of those is what snapped v1.7's video
        // back upright a moment after it rotated).
        OrientationHelper.setLock(.allButUpsideDown)
        let asset: AVURLAsset
        if startViaProxy, let proxied = HLSProxyLoader.proxiedURL(for: url) {
            // The playlist's segments sit behind a dead proxy host
            // (see MovieService.markProxyIfNeeded): build the first
            // item through the rescue loader — it unwraps them.
            let loader = HLSProxyLoader(headers: headers)
            context.coordinator.proxyLoader = loader
            context.coordinator.didRetryViaProxy = true
            let proxiedAsset = AVURLAsset(url: proxied)
            proxiedAsset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "jtv.hlsproxy.delegate"))
            asset = proxiedAsset
        } else {
            asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        context.coordinator.player = player
        context.coordinator.sourceURL = url
        context.coordinator.sourceHeaders = headers
        context.coordinator.startedViaProxy = startViaProxy
        context.coordinator.observe(item: item)

        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        context.coordinator.playerController = controller

        let interval = CMTime(seconds: 5, preferredTimescale: 1)
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.reportProgress()
        }
        context.coordinator.startPosition = startPosition

        // The player controller is PRESENTED modally by the host
        // instead of embedded. Embedded, the app had to draw its own
        // close X on top of AVKit's built-in chevron (two buttons
        // stacked in the same corner) and the player could not
        // rotate. Presented, AVKit shows exactly one close control,
        // its chevron really dismisses, and landscape works.
        let host = PlayerHostViewController()
        host.playerController = controller
        host.onPresented = { [weak coordinator = context.coordinator] in
            coordinator?.seekAndPlay()
        }
        host.onDismissed = onClose
        return host
    }

    func updateUIViewController(_ controller: PlayerHostViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: PlayerHostViewController, coordinator: Coordinator) {
        coordinator.reportExit()
        coordinator.observer.map { coordinator.player?.removeTimeObserver($0) }
        coordinator.observer = nil
        if let presented = controller.presentedViewController {
            presented.dismiss(animated: false)
        }
        controller.playerController?.player?.pause()
        // The player screen is really gone (the cover closed): the
        // app goes back to portrait-only.
        OrientationHelper.setLock(.portrait)
        OrientationHelper.requestGeometry(.portrait)
    }

    final class Coordinator {
        var player: AVPlayer?
        var playerController: AVPlayerViewController?
        var observer: Any?
        var startPosition: Double = 0
        private var didSeek = false
        private let onProgress: (Double, Double) -> Void
        private let onExit: (Double, Double) -> Void

        // HLS disguise rescue: if the plain item fails to load (the
        // CDN serves playlists/segments disguised as images, which
        // AVPlayer refuses), retry ONCE through HLSProxyLoader.
        // Streams that START through the proxy (segment-proxy
        // playlists, see MovieService) get the mirror-image safety
        // net: if the proxied item fails, fall back ONCE to the
        // plain URL — the two transports are independent, so
        // whichever one is broken on a given network, the other
        // carries the stream.
        var sourceURL: URL?
        var sourceHeaders: [String: String] = [:]
        var proxyLoader: HLSProxyLoader?
        private var statusObservation: NSKeyValueObservation?
        var didRetryViaProxy = false
        var startedViaProxy = false
        private var didFallBackToPlain = false

        init(onProgress: @escaping (Double, Double) -> Void, onExit: @escaping (Double, Double) -> Void) {
            self.onProgress = onProgress
            self.onExit = onExit
        }

        func observe(item: AVPlayerItem) {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    DispatchQueue.main.async { self?.handleFailure() }
                }
            }
        }

        private func handleFailure() {
            if startedViaProxy {
                if !didFallBackToPlain { fallBackToPlain() }
            } else {
                retryViaProxy()
            }
        }

        private func fallBackToPlain() {
            guard let player, let sourceURL else { return }
            didFallBackToPlain = true
            let asset = AVURLAsset(url: sourceURL, options: ["AVURLAssetHTTPHeaderFieldsKey": sourceHeaders])
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            observe(item: item)
            seekAndPlay()
        }

        private func retryViaProxy() {
            guard !didRetryViaProxy,
                  let player, let sourceURL,
                  let proxied = HLSProxyLoader.proxiedURL(for: sourceURL) else { return }
            didRetryViaProxy = true
            let loader = HLSProxyLoader(headers: sourceHeaders)
            proxyLoader = loader
            let asset = AVURLAsset(url: proxied)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "jtv.hlsproxy.delegate"))
            let item = AVPlayerItem(asset: asset)
            // If playback had already progressed, resume where it died.
            let pos = player.currentTime().seconds
            if pos.isFinite, pos > 10 {
                startPosition = pos
                didSeek = false
            }
            player.replaceCurrentItem(with: item)
            observe(item: item)
            seekAndPlay()
        }

        func seekAndPlay() {
            guard let player else { return }
            if startPosition > 10, !didSeek {
                didSeek = true
                let target = CMTime(seconds: startPosition, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 5, preferredTimescale: 600)) { _ in
                    player.play()
                }
            } else {
                player.play()
            }
        }

        private func times() -> (Double, Double) {
            guard let player, let item = player.currentItem else { return (0, 0) }
            let current = player.currentTime().seconds
            let duration = item.duration.seconds
            return (current.isFinite ? current : 0, duration.isFinite ? duration : 0)
        }

        func reportProgress() {
            let (c, d) = times()
            if c > 0 { onProgress(c, d) }
        }

        func reportExit() {
            let (c, d) = times()
            if c > 0 { onExit(c, d) }
        }
    }
}

/// Plain host that presents the AVPlayerViewController full-screen
/// and reports back when the user dismisses it (AVKit's chevron),
/// so the SwiftUI cover can close too.
///
/// Dismissal is learned ONLY from the presentation controller's
/// delegate callback — a deterministic UIKit signal. v1.7 inferred
/// it from the host's viewDidAppear ("visible again = player
/// dismissed"), but appearance callbacks in this hierarchy can
/// also fire while the player is merely taking the screen, which
/// closed the cover underneath a still-playing controller and
/// left it orphaned and unclosable.
final class PlayerHostViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    var playerController: AVPlayerViewController?
    var onPresented: (() -> Void)?
    var onDismissed: (() -> Void)?
    private var didPresent = false
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresent, let playerController else { return }
        didPresent = true
        playerController.modalPresentationStyle = .fullScreen
        playerController.presentationController?.delegate = self
        present(playerController, animated: true) { [weak self] in
            self?.onPresented?()
            // Video plays landscape: ask the scene to rotate
            // (the masks above plus the lock the surface opened
            // permit it; the user can rotate back freely).
            if let scene = self?.view.window?.windowScene {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
            }
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard didPresent, !didFinish else { return }
        didFinish = true
        onDismissed?()
    }
}

// MARK: - Player screen

struct PlayerView: View {
    let stream: StreamInfo
    let request: PlaybackRequest

    @EnvironmentObject private var history: WatchHistoryManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = stream.streamURL {
                VideoPlayerSurface(
                    url: url,
                    headers: stream.headers,
                    startPosition: request.startPosition,
                    startViaProxy: stream.requiresProxy,
                    onProgress: { save(position: $0, duration: $1, force: false) },
                    onExit: { save(position: $0, duration: $1, force: true) },
                    onClose: { dismiss() }
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 14) {
                    ContentUnavailableView("Không có link phát", systemImage: "exclamationmark.triangle",
                                           description: Text("Nguồn không trả về link phát cho tập này."))
                    Button("Đóng") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
            }

        }
        .statusBarHidden(true)
    }

    private func save(position: Double, duration: Double, force: Bool) {
        let record = HistoryRecord(
            pluginId: request.pluginId,
            pluginName: request.pluginName,
            isManga: false,
            movie: request.movie,
            serverName: request.serverName,
            episodeName: request.episode.name,
            episodeId: request.episode.id,
            streamURL: stream.url,
            lastPosition: position,
            duration: duration,
            updatedAt: Date()
        )
        history.upsert(record, force: force)
    }
}

// MARK: - Embed player (WKWebView + m3u8 sniffer)

struct EmbedPlayerView: View {
    let url: URL
    let headers: [String: String]
    var onCapture: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            EmbedWebView(url: url, headers: headers, onCapture: onCapture)
                .ignoresSafeArea()
            // No close chrome of its own: the resolver screen draws
            // one persistent close button above every phase (this
            // one included), so the exit is always in the same
            // place and can never be lost inside the web content.
        }
    }
}

private struct EmbedWebView: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]
    var onCapture: (String) -> Void

    static let snifferJS = """
    (function() {
      if (window.__jtvSniffer) return; window.__jtvSniffer = true;
      function report(u) {
        try {
          if (u && typeof u === 'string' && u.indexOf('.m3u8') !== -1 &&
              window.webkit && window.webkit.messageHandlers &&
              window.webkit.messageHandlers.m3u8Interceptor) {
            window.webkit.messageHandlers.m3u8Interceptor.postMessage(u);
          }
        } catch (e) {}
      }
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function() {
          var a = arguments[0];
          var reqUrl = typeof a === 'string' ? a : (a && a.url) || '';
          report(reqUrl);
          var p = origFetch.apply(this, arguments);
          // Player APIs (123av's /stream) hand the real stream URL
          // back in a JSON RESPONSE — the request URL never looks
          // like media, and the page may then play through a blob /
          // managed-media-source pipeline whose video.src the
          // poller cannot use. Read the response too.
          if (reqUrl.indexOf('/stream') !== -1) {
            p.then(function(r) {
              try {
                r.clone().json().then(function(j) {
                  var s = j && j.media && j.media.stream;
                  if (s) report(s);
                }).catch(function() {});
              } catch (e) {}
            }).catch(function() {});
          }
          return p;
        };
      }
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, u) {
        report(u);
        if (typeof u === 'string' && u.indexOf('/stream') !== -1) {
          this.addEventListener('load', function() {
            try {
              var j = JSON.parse(this.responseText);
              var s = j && j.media && j.media.stream;
              if (s) report(s);
            } catch (e) {}
          });
        }
        return origOpen.apply(this, arguments);
      };
      if (window.PerformanceObserver) {
        try {
          new PerformanceObserver(function(list) {
            list.getEntries().forEach(function(e) { report(e.name); });
          }).observe({ entryTypes: ['resource'] });
        } catch (e) {}
      }
      setInterval(function() {
        document.querySelectorAll('video').forEach(function(v) {
          if (v.currentSrc) report(v.currentSrc);
          if (v.src) report(v.src);
        });
      }, 1500);
    })();
    """

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    func makeUIViewController(context: Context) -> EmbedHostViewController {
        // The embed surface owns the orientation lock, exactly
        // like the native one: opened here, restored in dismantle.
        OrientationHelper.setLock(.allButUpsideDown)
        let userScript = WKUserScript(source: Self.snifferJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        let controller = WKUserContentController()
        controller.addUserScript(userScript)
        controller.add(context.coordinator, name: "m3u8Interceptor")

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Net.desktopUA
        webView.backgroundColor = .black
        webView.isOpaque = false

        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        webView.load(request)

        let host = EmbedHostViewController()
        host.webView = webView
        return host
    }

    func updateUIViewController(_ controller: EmbedHostViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: EmbedHostViewController, coordinator: Coordinator) {
        controller.webView?.configuration.userContentController.removeScriptMessageHandler(forName: "m3u8Interceptor")
        controller.webView?.stopLoading()
        OrientationHelper.setLock(.portrait)
        OrientationHelper.requestGeometry(.portrait)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        private let onCapture: (String) -> Void
        private var captured = false

        init(onCapture: @escaping (String) -> Void) {
            self.onCapture = onCapture
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "m3u8Interceptor",
                  let urlString = message.body as? String,
                  !captured, MediaURL.isDirectMedia(urlString) else { return }
            captured = true
            onCapture(urlString)
        }
    }
}

/// UIKit host for the embed webview: gives the embed the same
/// orientation behaviour as the native player (landscape on
/// appear, autorotate while open) with deterministic lifecycle —
/// viewDidAppear here only ever REQUESTS landscape, it never
/// restores anything, so a spurious appearance cannot fight it.
final class EmbedHostViewController: UIViewController {
    var webView: WKWebView?
    private var didRequestLandscape = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        if let webView {
            webView.frame = view.bounds
            webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(webView)
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didRequestLandscape {
            didRequestLandscape = true
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
    }
}

// MARK: - Resolver screen

/// Resolves a PlaybackRequest (direct / embed / manga) and routes to the
/// native player, the manga reader or the sniffing embed webview.
struct PlaybackResolverView: View {
    let request: PlaybackRequest

    @EnvironmentObject private var service: MovieService
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case resolving
        case video(StreamInfo)
        case manga(StreamInfo)
        case embed(URL, [String: String])
        case failed(String)
    }

    @State private var phase: Phase = .resolving

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            switch phase {
            case .resolving:
                VStack(spacing: 16) {
                    ProgressView().tint(Theme.accent).scaleEffect(1.3)
                    Text("Đang lấy link phát…")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                    Text(request.episode.name)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                }
            case .video(let stream):
                PlayerView(stream: stream, request: request)
            case .manga(let stream):
                MangaReaderView(
                    movie: request.movie,
                    pluginId: request.pluginId,
                    pluginName: request.pluginName,
                    serverName: request.serverName,
                    episodes: request.allEpisodes.isEmpty ? [request.episode] : request.allEpisodes,
                    startEpisode: request.episode,
                    initialStream: stream
                )
            case .embed(let url, let headers):
                EmbedPlayerView(url: url, headers: headers) { captured in
                    // Media CDNs behind embed players (123av's family,
                    // verified by direct fetch) accept media requests
                    // only with a Referer from the embed host itself —
                    // the plugin-site referer gets a 403 on playlist
                    // and segments alike. The webview page load keeps
                    // the original headers (that referer also exempts
                    // the page from its popunder); only the media
                    // handoff swaps the referer to the embed page.
                    var mediaHeaders = headers
                    mediaHeaders["Referer"] = url.absoluteString
                    let stream = StreamInfo(url: captured, headers: mediaHeaders)
                    phase = .video(stream)
                }
            case .failed(let message):
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.amber)
                    Text(message)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Đóng") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
                .padding(24)
            }

            // One persistent exit for the whole player screen,
            // drawn above every phase except the manga reader
            // (which has its own chrome). While the native player
            // is presented it sits in a separate hierarchy above
            // this cover, so the button is simply not visible then
            // — AVKit's own close rules. In every other state
            // (resolving, embed, failed, or a native host left
            // behind by a dismissal that did not propagate) this
            // button is here and always closes the screen. v1.6/
            // v1.7 trapped the user inside embed players and
            // orphaned native players; an exit that depends on the
            // content is not an exit.
            if showsCloseButton {
                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.black.opacity(0.45), in: Circle())
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding()
            }
        }
        .task {
            await resolve()
        }
        // No orientation code lives in SwiftUI anymore: appearance
        // hooks here fired at moments that had nothing to do with
        // the player leaving (the presented controller covering
        // the screen reads as "disappeared"), and their portrait
        // restore is what snapped rotated video back upright. The
        // UIKit player surfaces own the lock now.
    }

    private var showsCloseButton: Bool {
        switch phase {
        case .manga: return false
        default: return true
        }
    }

    private func resolve() async {
        do {
            let resolution = try await service.resolveEpisode(request)
            switch resolution {
            case .video(let stream): phase = .video(stream)
            case .manga(let stream): phase = .manga(stream)
            case .embed(let url, let headers): phase = .embed(url, headers)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
