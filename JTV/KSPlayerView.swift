import SwiftUI
import UIKit
import KSPlayer
import AVFoundation
import MediaPlayer

// MARK: - FFmpeg player surface (KSPlayer)
//
// Why this exists: debrid downloads are predominantly Matroska
// files, and AVFoundation has no Matroska demuxer — on the
// AVPlayer surface those titles could never produce a frame.
// KSPlayer's ME engine (FFmpeg) opens them natively. Only the
// debrid path is routed here (StreamInfo.useCompatEngine, set by
// DebridResolver from the chosen file's extension); every other
// source keeps the AVPlayer surface exactly as before.
//
// The surface mirrors PlayerSurfaceViewController's contract and
// control language — same buttons, same scrubber, same pinch
// thresholds, same landscape request, same error surface — so the
// two players feel like one. KSPlayer-specific rules are the ones
// proven on the TV build:
//   • the layer is created ONLY once the host view has real
//     bounds (creating it against a not-yet-laid-out view froze
//     the picture at the safe-area size on tvOS);
//   • the player view is sized by frame + autoresizingMask on
//     every layout pass, never by Auto Layout constraints;
//   • playback is requested explicitly with play();
//   • a 12 s first-frame budget and a 12 s mid-play freeze watch
//     mean no attempt can spin forever — failures land on the
//     same visible error surface as the AVPlayer path.
// Pinch-to-fill uses the engine's own switch, verified in the
// library source (2.3.4): MediaPlayerProtocol.contentMode maps
// .scaleAspectFill onto the ME renderer's resizeAspectFill.

struct KSPlayerView: View {
    let stream: StreamInfo
    let request: PlaybackRequest
    /// v1.22.4: source switching, owned by the resolver screen.
    var onSwitchSource: ((Episode) -> Void)?

    @EnvironmentObject private var history: WatchHistoryManager
    @EnvironmentObject private var service: MovieService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = stream.streamURL {
                KSVideoPlayerSurface(
                    url: url,
                    headers: stream.headers,
                    startPosition: request.startPosition,
                    title: request.movie.title,
                    patientMode: request.episode.id.hasPrefix("jtvhash:"),
                    sourceLabel: request.episode.name,
                    sources: request.allEpisodes.isEmpty ? [request.episode] : request.allEpisodes,
                    currentSourceId: request.episode.id,
                    onSwitchSource: onSwitchSource,
                    onFreshStream: {
                        // v1.22 self-heal's last rung (see the
                        // AV surface): re-resolve from scratch.
                        guard let resolution = try? await service.resolveEpisode(request),
                              case .video(let fresh) = resolution else { return nil }
                        return fresh
                    },
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

struct KSVideoPlayerSurface: UIViewControllerRepresentable {
    let url: URL
    let headers: [String: String]
    let startPosition: Double
    var title: String = ""
    /// v1.22.4: torrent patience + source identity/switching.
    var patientMode: Bool = false
    var sourceLabel: String = ""
    var sources: [Episode] = []
    var currentSourceId: String = ""
    var onSwitchSource: ((Episode) -> Void)?
    var onFreshStream: (() async -> StreamInfo?)?
    var onProgress: (Double, Double) -> Void
    var onExit: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress, onExit: onExit)
    }

    func makeUIViewController(context: Context) -> KSPlayerSurfaceViewController {
        OrientationHelper.setLock(.allButUpsideDown)
        let controller = KSPlayerSurfaceViewController()
        controller.contentURL = url
        controller.contentHeaders = headers
        controller.startPosition = startPosition
        controller.nowPlayingTitle = title
        controller.patientMode = patientMode
        controller.sourceLabelText = sourceLabel
        controller.sources = sources
        controller.currentSourceId = currentSourceId
        controller.onSwitchSource = onSwitchSource
        controller.freshStreamProvider = onFreshStream
        controller.onProgressTick = { [weak coordinator = context.coordinator] position, duration in
            coordinator?.onProgress(position, duration)
        }
        context.coordinator.controller = controller
        return controller
    }

    func updateUIViewController(_ controller: KSPlayerSurfaceViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: KSPlayerSurfaceViewController, coordinator: Coordinator) {
        coordinator.reportExit()
        controller.teardown()
    }

    final class Coordinator {
        let onProgress: (Double, Double) -> Void
        let onExit: (Double, Double) -> Void
        weak var controller: KSPlayerSurfaceViewController?
        private var didReportExit = false

        init(onProgress: @escaping (Double, Double) -> Void, onExit: @escaping (Double, Double) -> Void) {
            self.onProgress = onProgress
            self.onExit = onExit
        }

        func reportExit() {
            guard !didReportExit else { return }
            didReportExit = true
            guard let controller else { return }
            onExit(controller.currentPosition, controller.currentDuration)
        }
    }
}

final class KSPlayerSurfaceViewController: UIViewController, KSPlayerLayerDelegate {
    var contentURL: URL?
    var contentHeaders: [String: String] = [:]
    var startPosition: Double = 0
    var onProgressTick: ((Double, Double) -> Void)?
    /// Movie title for Now Playing (v1.22).
    var nowPlayingTitle = ""
    /// Re-resolves the episode from scratch (v1.22 self-heal).
    var freshStreamProvider: (() async -> StreamInfo?)?
    /// v1.22.4: torrent patience (deep buffer, long watchdogs)
    /// + source identity/switching, mirroring the AV surface.
    var patientMode = false
    var sourceLabelText = ""
    var sources: [Episode] = []
    var currentSourceId = ""
    var onSwitchSource: ((Episode) -> Void)?

    private var playerLayer: KSPlayerLayer?
    private var ready = false
    private var playing = false
    private var failed = false
    private var ended = false
    private var didSeekToStart = false
    private var firstFrameWatchdog: DispatchWorkItem?
    private var freezeTimer: Timer?
    private var lastPositionSec = -1.0
    private var lastAdvanceAt = Date()
    private var lastTickAt = Date.distantPast
    // v1.22 self-heal state (mirrors the AV surface's ladder).
    private var recoveryAttempts = 0
    private var lastRecoveryPosition = -1.0
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var lastNowPlayingPush = Date.distantPast

    private let controlsView = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let playPauseButton = UIButton(type: .system)
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let sourcesButton = UIButton(type: .system)
    private let sourceLabel = UILabel()
    private let slider = UISlider()
    private let currentLabel = UILabel()
    private let durationLabel = UILabel()
    private let errorLabel = UILabel()
    private var uiTimer: Timer?
    private var hideTimer: Timer?
    private var controlsVisible = true
    private var isScrubbing = false
    private var didRequestLandscape = false

    var currentPosition: Double {
        guard let playerLayer else { return 0 }
        let t = playerLayer.player.currentPlaybackTime
        return t.isFinite ? t : 0
    }

    var currentDuration: Double {
        guard let playerLayer else { return 0 }
        let d = playerLayer.player.duration
        return d.isFinite ? d : 0
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
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
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        view.addGestureRecognizer(pinch)

        // v1.22: background audio + Now Playing, same as the AV
        // surface. (PiP is NOT available on this surface: the ME
        // engine renders through Metal, which the system's PiP
        // controller cannot float.)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .moviePlayback)
        try? audioSession.setActive(true)
        setupRemoteCommands()

        uiTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshUI()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        beginPlaybackIfPossible()
        if !didRequestLandscape {
            didRequestLandscape = true
            view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))
        }
        scheduleControlsHide()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The library contract is frame-based: re-assert the
        // player surface's frame against the host's real bounds
        // on EVERY layout pass.
        if let playerView = playerLayer?.player.view {
            playerView.frame = view.bounds
        }
        beginPlaybackIfPossible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        uiTimer?.invalidate()
        hideTimer?.invalidate()
        teardownRemoteCommands()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }

    // MARK: - Playback start (deferred until real bounds exist)

    private func beginPlaybackIfPossible() {
        guard playerLayer == nil,
              let url = contentURL,
              view.bounds.width > 0, view.bounds.height > 0
        else { return }
        let options = KSOptions()
        options.userAgent = contentHeaders["User-Agent"] ?? Net.desktopUA
        if !contentHeaders.isEmpty {
            options.appendHeader(contentHeaders)
        }
        // v1.22 buffer tuning (verified against the 2.3.4
        // library source): the stock 3 s forward buffer makes
        // the engine re-stall on every slow segment; 12 s
        // matches the AV surface's setting.
        // v1.22.4: torrent files hold 30 s (see the AV surface).
        options.preferredForwardBufferDuration = patientMode ? 30 : 12
        KSOptions.firstPlayerType = KSMEPlayer.self
        let layer = KSPlayerLayer(url: url, options: options, delegate: self)
        playerLayer = layer
        if let playerView = layer.player.view {
            playerView.frame = view.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(playerView, at: 0)
        }
        layer.play()

        // v1.22.4: torrent files get a 30 s first-frame budget —
        // a debrid CDN's cold start after a far seek is slow, and
        // the 12 s budget declared healthy files dead.
        let firstFrameBudget: TimeInterval = patientMode ? 30 : 12
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.playing else { return }
            self.handlePlaybackFailure(message: "Chưa có hình sau \(Int(firstFrameBudget)) giây.")
        }
        firstFrameWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + firstFrameBudget, execute: watchdog)

        lastAdvanceAt = Date()
        let ticker = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkFreeze()
        }
        RunLoop.main.add(ticker, forMode: .common)
        freezeTimer = ticker
    }

    func teardown() {
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        freezeTimer?.invalidate()
        freezeTimer = nil
        teardownRemoteCommands()
        playerLayer?.delegate = nil
        playerLayer?.stop()
        playerLayer = nil
    }

    // MARK: - KSPlayerLayerDelegate

    func player(layer: KSPlayerLayer, state: KSPlayerState) {
        switch state {
        case .readyToPlay:
            firstFrameWatchdog?.cancel()
            if !ready {
                ready = true
                if !didSeekToStart, startPosition > 5 {
                    didSeekToStart = true
                    layer.seek(time: startPosition, autoPlay: true) { _ in }
                }
            }
        case .bufferFinished:
            if !playing {
                playing = true
                firstFrameWatchdog?.cancel()
                lastAdvanceAt = Date()
                let now = layer.player.currentPlaybackTime
                lastPositionSec = now.isFinite ? now : -1
            }
            spinner.stopAnimating()
        case .error:
            handlePlaybackFailure(message: "Engine phát báo lỗi.")
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        // Healthy playback well past the death position refills
        // the self-heal budget (checked before the 5 s throttle).
        if lastRecoveryPosition >= 0, currentTime.isFinite, currentTime > lastRecoveryPosition + 5 {
            recoveryAttempts = 0
            lastRecoveryPosition = -1
        }
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= 5 else { return }
        lastTickAt = now
        onProgressTick?(currentTime.isFinite ? currentTime : 0,
                        totalTime.isFinite ? totalTime : 0)
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            handlePlaybackFailure(message: error.localizedDescription)
        } else {
            ended = true
        }
    }

    func player(layer: KSPlayerLayer, bufferedCount: Int, consumeTime: TimeInterval) {}

    // MARK: - Freeze watch (12 s without playhead advance)

    private func checkFreeze() {
        guard playing, !ended, !failed, let layer = playerLayer else { return }
        if layer.state == .paused || !layer.player.isPlaying {
            lastAdvanceAt = Date()
            let now = layer.player.currentPlaybackTime
            if now.isFinite { lastPositionSec = now }
            return
        }
        let pos = layer.player.currentPlaybackTime
        guard pos.isFinite else { return }
        let dur = layer.player.duration
        if dur.isFinite, dur > 0, pos >= dur - 1.5 {
            lastAdvanceAt = Date()
            lastPositionSec = pos
            return
        }
        if lastPositionSec >= 0, abs(pos - lastPositionSec) > 0.05 {
            lastPositionSec = pos
            lastAdvanceAt = Date()
            return
        }
        lastPositionSec = pos
        // v1.22.4: torrent files get a 30 s freeze window (their
        // CDN refills slowly after a far seek; 12 s killed them).
        let freezeBudget: TimeInterval = patientMode ? 30 : 12
        if Date().timeIntervalSince(lastAdvanceAt) > freezeBudget {
            handlePlaybackFailure(message: "Hình đứng quá \(Int(freezeBudget)) giây — đường truyền tới file có vấn đề.")
        }
    }

    // MARK: - Self-heal (v1.22) + remote commands

    /// The KS mirror of the AV surface's mid-playback self-heal:
    /// this surface previously had ZERO recovery — the first
    /// engine error or 12 s freeze went straight to the error
    /// screen. A failure AFTER playback began now retries the
    /// same URL twice (backoff 2 s / 5 s) by rebuilding the
    /// layer at the death position, then tries one completely
    /// fresh resolve, and only then shows the error. Failures
    /// before the first frame keep the old straight-to-error
    /// behaviour.
    private func handlePlaybackFailure(message: String?) {
        guard playing, !failed, recoveryAttempts < 3 else {
            showError(message: message)
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let deathPos = currentPosition
        if deathPos > 1 {
            startPosition = deathPos
            lastRecoveryPosition = deathPos
        }
        freezeTimer?.invalidate()
        freezeTimer = nil
        let delay: Double = attempt == 1 ? 2 : (attempt == 2 ? 5 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.failed else { return }
            if attempt < 3 {
                self.restartLayer()
            } else if let provider = self.freshStreamProvider {
                Task { [weak self] in
                    let fresh = await provider()
                    await MainActor.run {
                        guard let self, !self.failed else { return }
                        if let fresh, let freshURL = fresh.streamURL, fresh.useCompatEngine {
                            self.contentURL = freshURL
                            self.contentHeaders = fresh.headers
                            self.restartLayer()
                        } else {
                            self.showError(message: message)
                        }
                    }
                }
            } else {
                self.showError(message: message)
            }
        }
    }

    /// Tears the dead layer down and builds a fresh one; the
    /// ready-to-play seek lands it on `startPosition`, which the
    /// failure handler set to the death position.
    private func restartLayer() {
        firstFrameWatchdog?.cancel()
        firstFrameWatchdog = nil
        playerLayer?.delegate = nil
        playerLayer?.stop()
        if let playerView = playerLayer?.player.view {
            playerView.removeFromSuperview()
        }
        playerLayer = nil
        ready = false
        playing = false
        didSeekToStart = false
        ended = false
        lastPositionSec = -1
        lastAdvanceAt = Date()
        controlsView.isHidden = false
        spinner.startAnimating()
        beginPlaybackIfPossible()
    }

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        remoteTargets.append((center.playCommand, center.playCommand.addTarget { [weak self] _ in
            self?.playerLayer?.play()
            return .success
        }))
        remoteTargets.append((center.pauseCommand, center.pauseCommand.addTarget { [weak self] _ in
            self?.playerLayer?.pause()
            return .success
        }))
        remoteTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let layer = self?.playerLayer else { return .commandFailed }
            if layer.state.isPlaying { layer.pause() } else { layer.play() }
            return .success
        }))
        remoteTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent,
                  let layer = self?.playerLayer else { return .commandFailed }
            layer.seek(time: positionEvent.positionTime, autoPlay: true) { _ in }
            return .success
        }))
    }

    private func teardownRemoteCommands() {
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Error surface (same shape as the AVPlayer surface)

    func showError(message: String? = nil) {
        guard !failed else { return }
        failed = true
        firstFrameWatchdog?.cancel()
        spinner.stopAnimating()
        controlsView.isHidden = true
        if let message, !message.isEmpty {
            errorLabel.text = "Không phát được nguồn này.\n\(message)"
        }
        errorLabel.isHidden = false
    }

    // MARK: - Controls (mirrors PlayerSurfaceViewController)

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
        slider.addTarget(self, action: #selector(scrubChanged), for: .valueChanged)
        slider.addTarget(self, action: #selector(scrubEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

        rotateButton.setImage(UIImage(systemName: "crop.rotate"), for: .normal)
        rotateButton.tintColor = .white
        rotateButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        rotateButton.layer.cornerRadius = 20
        rotateButton.translatesAutoresizingMaskIntoConstraints = false
        rotateButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        rotateButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        rotateButton.addTarget(self, action: #selector(toggleRotation), for: .touchUpInside)

        // v1.22.4: source identity + switching (mirrors the AV
        // surface's control layer).
        sourcesButton.setImage(UIImage(systemName: "list.bullet"), for: .normal)
        sourcesButton.tintColor = .white
        sourcesButton.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        sourcesButton.layer.cornerRadius = 20
        sourcesButton.translatesAutoresizingMaskIntoConstraints = false
        sourcesButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        sourcesButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        sourcesButton.addTarget(self, action: #selector(showSourceList), for: .touchUpInside)
        sourcesButton.isHidden = sources.count <= 1

        sourceLabel.text = sourceLabelText.isEmpty ? "" : "Nguồn: \(sourceLabelText)"
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = UIColor.white.withAlphaComponent(0.85)
        sourceLabel.numberOfLines = 1
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceLabel.isHidden = sourceLabelText.isEmpty
        controlsView.addSubview(sourceLabel)

        let bottomRow = UIStackView(arrangedSubviews: [currentLabel, slider, durationLabel, sourcesButton, rotateButton])
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
            sourceLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            sourceLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
        ])
    }

    /// v1.22.4: the sibling-source picker (see the AV surface).
    @objc private func showSourceList() {
        let sheet = UIAlertController(title: "Chọn nguồn khác", message: "Nguồn đang phát: \(sourceLabelText)", preferredStyle: .actionSheet)
        for episode in sources {
            let isCurrent = episode.id == currentSourceId
            let action = UIAlertAction(title: (isCurrent ? "✓ " : "") + episode.name, style: .default) { [weak self] _ in
                guard !isCurrent else { return }
                self?.onSwitchSource?(episode)
            }
            action.isEnabled = !isCurrent
            sheet.addAction(action)
        }
        sheet.addAction(UIAlertAction(title: "Huỷ", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = sourcesButton
            pop.sourceRect = sourcesButton.bounds
        }
        present(sheet, animated: true)
    }

    private func refreshUI() {
        guard let layer = playerLayer, !failed else { return }
        let current = layer.player.currentPlaybackTime
        let duration = layer.player.duration
        if duration.isFinite, duration > 0 {
            durationLabel.text = Self.formatTime(duration)
            if !isScrubbing {
                slider.maximumValue = Float(duration)
                slider.value = Float(current.isFinite ? current : 0)
            }
        }
        currentLabel.text = Self.formatTime(current.isFinite ? current : 0)
        let isPlaying = layer.player.isPlaying
        playPauseButton.setImage(UIImage(systemName: isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        if playing, layer.state == .buffering {
            spinner.startAnimating()
        } else if playing {
            spinner.stopAnimating()
        }
        // Now Playing, ~1 Hz like the AV surface.
        if Date().timeIntervalSince(lastNowPlayingPush) > 1 {
            lastNowPlayingPush = Date()
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: nowPlayingTitle.isEmpty ? "JTV" : nowPlayingTitle,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: current.isFinite ? current : 0,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyIsLiveStream: false,
            ]
            if duration.isFinite, duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
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
            guard let self, self.playerLayer?.player.isPlaying == true else { return }
            self.controlsVisible = false
            UIView.animate(withDuration: 0.25) { self.controlsView.alpha = 0 }
        }
    }

    @objc private func togglePlay() {
        guard let layer = playerLayer else { return }
        if layer.state.isPlaying {
            layer.pause()
        } else {
            layer.play()
        }
        refreshUI()
        scheduleControlsHide()
    }

    @objc private func skipBack() { skip(by: -10) }
    @objc private func skipForward() { skip(by: 10) }

    private func skip(by delta: Double) {
        guard let layer = playerLayer else { return }
        let target = max(0, layer.player.currentPlaybackTime + delta)
        layer.seek(time: target, autoPlay: true) { _ in }
        scheduleControlsHide()
    }

    @objc private func scrubBegan() {
        isScrubbing = true
        hideTimer?.invalidate()
    }

    @objc private func scrubChanged() {
        currentLabel.text = Self.formatTime(Double(slider.value))
    }

    @objc private func scrubEnded() {
        isScrubbing = false
        guard let layer = playerLayer else { return }
        layer.seek(time: Double(slider.value), autoPlay: true) { _ in }
        scheduleControlsHide()
    }

    @objc private func toggleRotation() {
        let isLandscape = view.bounds.width > view.bounds.height
        view.window?.windowScene?.requestGeometryUpdate(
            .iOS(interfaceOrientations: isLandscape ? .portrait : .landscape))
        scheduleControlsHide()
    }

    /// Pinch out stretches the picture to fill the screen, pinch
    /// in returns to the full frame — the same gesture the
    /// AVPlayer surface answers (v1.20), driven through the ME
    /// engine's own contentMode switch.
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        guard let layer = playerLayer else { return }
        if gesture.scale > 1.15, layer.player.contentMode != .scaleAspectFill {
            layer.player.contentMode = .scaleAspectFill
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else if gesture.scale < 0.87, layer.player.contentMode != .scaleAspectFit {
            layer.player.contentMode = .scaleAspectFit
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}
