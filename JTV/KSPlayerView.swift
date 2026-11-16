import SwiftUI
import UIKit
import KSPlayer

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

    @EnvironmentObject private var history: WatchHistoryManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = stream.streamURL {
                KSVideoPlayerSurface(
                    url: url,
                    headers: stream.headers,
                    startPosition: request.startPosition,
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
        KSOptions.firstPlayerType = KSMEPlayer.self
        let layer = KSPlayerLayer(url: url, options: options, delegate: self)
        playerLayer = layer
        if let playerView = layer.player.view {
            playerView.frame = view.bounds
            playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.insertSubview(playerView, at: 0)
        }
        layer.play()

        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.playing else { return }
            self.showError(message: "Chưa có hình sau 12 giây.")
        }
        firstFrameWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: watchdog)

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
            showError(message: "Engine phát báo lỗi.")
        default:
            break
        }
    }

    func player(layer: KSPlayerLayer, currentTime: TimeInterval, totalTime: TimeInterval) {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= 5 else { return }
        lastTickAt = now
        onProgressTick?(currentTime.isFinite ? currentTime : 0,
                        totalTime.isFinite ? totalTime : 0)
    }

    func player(layer: KSPlayerLayer, finish error: Error?) {
        if let error {
            showError(message: error.localizedDescription)
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
        if Date().timeIntervalSince(lastAdvanceAt) > 12 {
            showError(message: "Hình đứng quá 12 giây — đường truyền tới file có vấn đề.")
        }
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
