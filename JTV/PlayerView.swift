import SwiftUI
import AVKit
import WebKit

// MARK: - Native player surface

/// Custom player surface: a plain view controller hosting an
/// AVPlayerLayer plus our own control layer — NO
/// AVPlayerViewController anywhere.
///
/// Why (the v1.6–v1.8 saga): every attempt that PRESENTED
/// AVPlayerViewController modally failed on device in a different
/// way — rotation denied or snapped back, the dismissal inferred
/// from appearance callbacks closed the cover under a live
/// player, the cover's own dismissal raced the player's and the
/// resolver re-ran and restarted the video, and the user always
/// ended up needing two different close buttons. AVKit's
/// presented-player machinery is the common factor in all of it,
/// so it is gone. What remains is the architecture that provably
/// works on this device (the embed host): a plain view controller
/// in the cover, orientation requested from its own lifecycle,
/// and exactly ONE close button — the resolver screen's, which
/// calls dismiss() directly and always lands.
struct VideoPlayerSurface: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]
    let startPosition: Double
    var startViaProxy: Bool = false
    var onProgress: (Double, Double) -> Void
    var onExit: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onExit: onExit)
    }

    func makeUIViewController(context: Context) -> PlayerSurfaceViewController {
        // Playback may rotate; the rest of the app may not. The
        // surface owns the lock: opened here, restored in dismantle
        // (the one callback that only runs when the player screen
        // is really gone).
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

        let interval = CMTime(seconds: 5, preferredTimescale: 1)
        context.coordinator.observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak coordinator = context.coordinator] _ in
            coordinator?.reportProgress()
        }
        context.coordinator.startPosition = startPosition

        let controller = PlayerSurfaceViewController()
        controller.player = player
        controller.coordinator = context.coordinator
        context.coordinator.onGiveUp = { [weak controller] message in
            controller?.showError(message: message)
        }
        if startViaProxy {
            // For playlists that flatten to direct URLs, start
            // the playback ladder (loopback server first — the
            // shape Safari proved); the loader item above is the
            // placeholder until the ladder's first rung lands.
            context.coordinator.upgradeProxyStream()
        }
        return controller
    }

    func updateUIViewController(_ controller: PlayerSurfaceViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: PlayerSurfaceViewController, coordinator: Coordinator) {
        coordinator.reportExit()
        coordinator.observer.map { coordinator.player?.removeTimeObserver($0) }
        coordinator.observer = nil
        coordinator.player?.pause()
        // No orientation restore here: the resolver screen owns it
        // (its onDisappear is the one signal that always means the
        // player screen closed).
    }

    final class Coordinator {
        var player: AVPlayer?
        var observer: Any?
        var startPosition: Double = 0
        private var didSeek = false
        private let onProgress: (Double, Double) -> Void
        private let onExit: (Double, Double) -> Void

        // HLS disguise rescue + dual transport: a stream that
        // starts plain falls back ONCE to the rescue proxy when its
        // item fails OR stalls; a stream that starts through the
        // proxy falls back ONCE to the plain URL. The two
        // transports are independent, so whichever one is broken
        // on a given network, the other carries the stream. If the
        // second transport also fails or stalls, the surface is
        // told to show an error instead of spinning forever —
        // a stall (dead segment host) never marks the item failed,
        // which is why failure-only detection was not enough.
        var sourceURL: URL?
        var sourceHeaders: [String: String] = [:]
        var proxyLoader: HLSProxyLoader?
        private var statusObservation: NSKeyValueObservation?
        var didRetryViaProxy = false
        var startedViaProxy = false
        private var didFallBackToPlain = false
        private var transportSwitched = false
        private var stallTimer: Timer?
        var onGiveUp: ((String?) -> Void)?
        private var didMaterialize = false
        private var ladderPending = false
        private var materializedFileURL: URL?
        private var proxyStage = 0   // 0 loader, 1 loopback server, 2 local file, 3 plain

        /// The playback ladder for proxy-first streams whose
        /// playlist flattens to direct URLs (the streamxx
        /// pattern — see HLSProxyLoader.materializedPlaylist).
        /// Safari proved a NETWORK-served copy of the rewritten
        /// playlist plays on the user's phone, while the custom-
        /// scheme loader never did across five builds and the
        /// local file did not either. So the ladder tries, in
        /// order: (1) the same bytes served from a loopback HTTP
        /// server as an ordinary network playlist — the closest
        /// in-app replica of the Safari proof; (2) the local
        /// file; (3) the original URL; the loader item built at
        /// surface creation is the placeholder underneath, and
        /// the existing fail/stall machinery advances the ladder.
        /// If materialization declines (anything still needs the
        /// loader), the ladder never starts and behaviour is
        /// exactly the pre-ladder dual transport.
        func upgradeProxyStream() {
            guard !didMaterialize, let sourceURL else { return }
            didMaterialize = true
            ladderPending = true
            let headers = sourceHeaders
            Task { [weak self] in
                let prepared = await HLSProxyLoader.materializedPlaylist(url: sourceURL, headers: headers)
                await MainActor.run {
                    guard let self else { return }
                    self.ladderPending = false
                    guard let prepared else {
                        // Declined: if the placeholder item
                        // already died while waiting, advance the
                        // normal fallback now.
                        if self.player?.currentItem?.status == .failed { self.handleFailure() }
                        return
                    }
                    self.materializedFileURL = prepared.fileURL
                    LocalHLSServer.shared.register(prepared.data) { [weak self] url in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            if let url {
                                self.proxyStage = 1
                                self.swapItem(AVPlayerItem(url: url))
                            } else {
                                self.proxyStage = 2
                                self.swapItem(AVPlayerItem(url: prepared.fileURL))
                            }
                        }
                    }
                }
            }
        }

        private func swapItem(_ item: AVPlayerItem) {
            guard let player else { return }
            let pos = player.currentTime().seconds
            if pos.isFinite, pos > 10 {
                startPosition = pos
                didSeek = false
            }
            player.replaceCurrentItem(with: item)
            observe(item: item)
            seekAndPlay()
        }

        private func lastErrorText() -> String? {
            player?.currentItem?.error?.localizedDescription
        }

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
            armStallTimer(for: item)
        }

        /// A stream whose segments are dead does not fail — it
        /// buffers forever with an empty loaded range. Give a new
        /// item 12 seconds to produce ANY buffered media or
        /// playback progress; if it produced neither, treat it
        /// exactly like a failure (switch transport once, then
        /// give up visibly). The window is generous on purpose:
        /// tunnel-routed sources are slow, not stalled, and they
        /// buffer something well inside it.
        private func armStallTimer(for item: AVPlayerItem) {
            stallTimer?.invalidate()
            stallTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self, weak item] _ in
                guard let self, let item, self.player?.currentItem === item else { return }
                let progressed = (self.player?.currentTime().seconds ?? 0) > 0.5
                let buffered = !item.loadedTimeRanges.isEmpty
                if !progressed && !buffered && self.player?.timeControlStatus != .playing {
                    self.handleFailure()
                }
            }
        }

        private func handleFailure() {
            stallTimer?.invalidate()
            if startedViaProxy, didMaterialize {
                // Proxy-first ladder (see upgradeProxyStream):
                // loopback server → local file → plain URL,
                // then give up with the player's own error text.
                if ladderPending {
                    // The ladder has not landed yet; give the
                    // current item another stall window instead
                    // of giving up underneath it.
                    if let item = player?.currentItem { armStallTimer(for: item) }
                    return
                }
                if proxyStage == 1, let fileURL = materializedFileURL {
                    proxyStage = 2
                    swapItem(AVPlayerItem(url: fileURL))
                    return
                }
                if proxyStage <= 2, !didFallBackToPlain {
                    proxyStage = 3
                    fallBackToPlain()
                    return
                }
                onGiveUp?(lastErrorText())
                return
            }
            if transportSwitched {
                onGiveUp?(lastErrorText())
                return
            }
            transportSwitched = true
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

/// The player's view controller: an AVPlayerLayer view with a
/// minimal control layer (play/pause, ±10 s, scrubber, times, a
/// rotate toggle, a buffering spinner). It deliberately draws NO
/// close button — the resolver screen's persistent X is the one
/// and only exit, and it sits above this controller in the same
/// cover, always visible.
final class PlayerSurfaceViewController: UIViewController {
    var player: AVPlayer?
    weak var coordinator: VideoPlayerSurface.Coordinator?

    private let videoView = PlayerLayerView()
    private let controlsView = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let playPauseButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let slider = UISlider()
    private let currentLabel = UILabel()
    private let durationLabel = UILabel()
    private let errorLabel = UILabel()
    private var gaveUp = false
    private var uiTimer: Timer?
    private var hideTimer: Timer?
    private var controlsVisible = true
    private var isScrubbing = false
    private var didStartPlayback = false
    private var didRequestLandscape = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.playerLayer.videoGravity = .resizeAspect
        videoView.player = player
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)

        buildControls()
        spinner.color = .white
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        spinner.startAnimating()

        errorLabel.text = "Không phát được nguồn này.\nThử nguồn khác hoặc thử lại sau."
        errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
        errorLabel.textColor = .white
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(errorLabel)
        NSLayoutConstraint.activate([
            errorLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            errorLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        view.addGestureRecognizer(tap)

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didStartPlayback {
            didStartPlayback = true
            coordinator?.seekAndPlay()
        }
        // Same proven pattern as the embed host: a plain view
        // controller in the cover asking the scene for landscape
        // once — this is the request shape the device honours.
        if !didRequestLandscape {
            didRequestLandscape = true
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
        scheduleControlsHide()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        uiTimer?.invalidate()
        hideTimer?.invalidate()
    }

    // MARK: Controls

    private func buildControls() {
        controlsView.frame = view.bounds
        controlsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controlsView)

        backButton.setImage(UIImage(systemName: "gobackward.10"), for: .normal)
        forwardButton.setImage(UIImage(systemName: "goforward.10"), for: .normal)
        for (button, action) in [(backButton, #selector(skipBack)), (forwardButton, #selector(skipForward))] {
            button.tintColor = .white
            button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
            button.layer.cornerRadius = 26
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 52).isActive = true
            button.heightAnchor.constraint(equalToConstant: 52).isActive = true
            button.addTarget(self, action: action, for: .touchUpInside)
        }
        playPauseButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        playPauseButton.layer.cornerRadius = 34
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.widthAnchor.constraint(equalToConstant: 68).isActive = true
        playPauseButton.heightAnchor.constraint(equalToConstant: 68).isActive = true
        playPauseButton.addTarget(self, action: #selector(togglePlay), for: .touchUpInside)

        let centerRow = UIStackView(arrangedSubviews: [backButton, playPauseButton, forwardButton])
        centerRow.axis = .horizontal
        centerRow.spacing = 28
        centerRow.alignment = .center
        centerRow.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(centerRow)

        for label in [currentLabel, durationLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.text = "0:00"
            label.translatesAutoresizingMaskIntoConstraints = false
        }
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.35)
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.addTarget(self, action: #selector(scrubBegan), for: .touchDown)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        rotateButton.setImage(UIImage(systemName: "crop.rotate"), for: .normal)
        rotateButton.tintColor = .white
        rotateButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        rotateButton.layer.cornerRadius = 20
        rotateButton.translatesAutoresizingMaskIntoConstraints = false
        rotateButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        rotateButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        rotateButton.addTarget(self, action: #selector(toggleRotation), for: .touchUpInside)

        let bottomRow = UIStackView(arrangedSubviews: [currentLabel, slider, durationLabel, rotateButton])
        bottomRow.axis = .horizontal
        bottomRow.spacing = 10
        bottomRow.alignment = .center
        bottomRow.translatesAutoresizingMaskIntoConstraints = false
        controlsView.addSubview(bottomRow)

        NSLayoutConstraint.activate([
            centerRow.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            centerRow.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            bottomRow.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bottomRow.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bottomRow.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14),
        ])
    }

    /// Both transports failed or stalled: stop pretending and
    /// say so — the resolver's close button is right there.
    func showError(message: String? = nil) {
        gaveUp = true
        spinner.stopAnimating()
        controlsView.isHidden = true
        if let message, !message.isEmpty {
            // Surface the player's own error text under the
            // plain-language line: it names the exact failure
            // (a rejected playlist, an unreachable host), which
            // is the evidence needed to fix a source for good
            // instead of guessing at it.
            errorLabel.text = "Không phát được nguồn này.\n\(message)"
        }
        errorLabel.isHidden = false
    }

    private func refreshUI() {
        guard let player, let item = player.currentItem else { return }
        let current = player.currentTime().seconds
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0 {
            durationLabel.text = Self.formatTime(duration)
            if !isScrubbing {
                slider.maximumValue = Float(duration)
                slider.value = Float(current.isFinite ? current : 0)
            }
        }
        currentLabel.text = Self.formatTime(current.isFinite ? current : 0)
        let playing = player.timeControlStatus == .playing
        playPauseButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        let waiting = !gaveUp && (player.timeControlStatus == .waitingToPlayAtSpecifiedRate || item.status != .readyToPlay)
        if waiting { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    @objc private func toggleControls() {
        controlsVisible.toggle()
        UIView.animate(withDuration: 0.2) {
            self.controlsView.alpha = self.controlsVisible ? 1 : 0
        }
        if controlsVisible { scheduleControlsHide() } else { hideTimer?.invalidate() }
    }

    private func scheduleControlsHide() {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            guard let self, self.player?.timeControlStatus == .playing else { return }
            self.controlsVisible = false
            UIView.animate(withDuration: 0.25) { self.controlsView.alpha = 0 }
        }
    }

    @objc private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
        refreshUI()
        scheduleControlsHide()
    }

    @objc private func skipBack() { skip(by: -10) }
    @objc private func skipForward() { skip(by: 10) }

    private func skip(by delta: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + delta)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        scheduleControlsHide()
    }

    @objc private func scrubBegan() {
        isScrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func scrubEnded() {
        isScrubbing = false
        guard let player else { return }
        player.seek(to: CMTime(seconds: Double(slider.value), preferredTimescale: 600))
        scheduleControlsHide()
    }

    @objc private func toggleRotation() {
        let isLandscape = view.bounds.width > view.bounds.height
        view.window?.windowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: isLandscape ? .portrait : .landscape))
        scheduleControlsHide()
    }
}

/// A view whose backing layer is an AVPlayerLayer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
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
                    onExit: { save(position: $0, duration: $1, force: true) }
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
      // The page player's own fullscreen is a trap: its X only
      // exits fullscreen (back to the page), and page taps can
      // bounce the video in and out of it — the user ends up
      // hunting for an exit that belongs to the page, not the
      // app. Playback stays inline (the app rotates the whole
      // page to landscape instead), and the app's own close
      // button is always visible. Neutralise both fullscreen
      // entry points the page can call from script.
      try {
        if (window.HTMLVideoElement && HTMLVideoElement.prototype) {
          HTMLVideoElement.prototype.webkitEnterFullscreen = function() {};
        }
        if (window.Element && Element.prototype && Element.prototype.requestFullscreen) {
          Element.prototype.requestFullscreen = function() { return Promise.resolve(); };
        }
      } catch (e) {}
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
        // No orientation restore here either: promotion to the
        // native player dismantles this surface too, and the
        // resolver owns the restore for the whole screen.
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
        // Orientation restore lives HERE and only here. Nothing
        // presents over this cover anymore (no modal player, no
        // webview fullscreen), so the resolver's onDisappear can
        // only mean the player screen really closed. v1.9 kept
        // the restore inside each surface's dismantle — but the
        // embed surface is ALSO dismantled when a sniffed stream
        // promotes the phase from embed to native video (123av,
        // javhd), and its portrait request landed after the new
        // surface's landscape request, snapping exactly those two
        // sources back upright. Direct sources never create an
        // embed, so they rotated fine.
        .onDisappear {
            OrientationHelper.setLock(.portrait)
            OrientationHelper.requestGeometry(.portrait)
        }
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
