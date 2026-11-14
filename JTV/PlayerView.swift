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
    var onProgress: (Double, Double) -> Void
    var onExit: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onExit: onExit)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        context.coordinator.player = player
        context.coordinator.sourceURL = url
        context.coordinator.sourceHeaders = headers
        context.coordinator.observe(item: item)

        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true

        let interval = CMTime(seconds: 5, preferredTimescale: 1)
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.reportProgress()
        }
        context.coordinator.startPosition = startPosition
        context.coordinator.seekAndPlay()
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        coordinator.reportExit()
        coordinator.observer.map { coordinator.player?.removeTimeObserver($0) }
        coordinator.observer = nil
        controller.player?.pause()
    }

    final class Coordinator {
        var player: AVPlayer?
        var observer: Any?
        var startPosition: Double = 0
        private var didSeek = false
        private let onProgress: (Double, Double) -> Void
        private let onExit: (Double, Double) -> Void

        // HLS disguise rescue: if the plain item fails to load (the
        // CDN serves playlists/segments disguised as images, which
        // AVPlayer refuses), retry ONCE through HLSProxyLoader.
        var sourceURL: URL?
        var sourceHeaders: [String: String] = [:]
        private var proxyLoader: HLSProxyLoader?
        private var statusObservation: NSKeyValueObservation?
        private var didRetryViaProxy = false

        init(onProgress: @escaping (Double, Double) -> Void, onExit: @escaping (Double, Double) -> Void) {
            self.onProgress = onProgress
            self.onExit = onExit
        }

        func observe(item: AVPlayerItem) {
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    DispatchQueue.main.async { self?.retryViaProxy() }
                }
            }
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
                    onProgress: { save(position: $0, duration: $1, force: false) },
                    onExit: { save(position: $0, duration: $1, force: true) }
                )
                .ignoresSafeArea()
            } else {
                ContentUnavailableView("Không có link phát", systemImage: "exclamationmark.triangle",
                                       description: Text("Nguồn không trả về link phát cho tập này."))
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                }
                Spacer()
                if !stream.subtitles.isEmpty {
                    Text("Phụ đề: " + stream.subtitles.map { $0.displayName }.joined(separator: ", "))
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 10)
                }
            }
            .padding()
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
        EmbedWebView(url: url, headers: headers, onCapture: onCapture)
            .ignoresSafeArea()
    }
}

private struct EmbedWebView: UIViewRepresentable {
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
          report(typeof a === 'string' ? a : (a && a.url) || '');
          return origFetch.apply(this, arguments);
        };
      }
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, u) {
        report(u);
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

    func makeUIView(context: Context) -> WKWebView {
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
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "m3u8Interceptor")
        webView.stopLoading()
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
                    let stream = StreamInfo(url: captured, headers: headers)
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
        }
        .task {
            await resolve()
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
