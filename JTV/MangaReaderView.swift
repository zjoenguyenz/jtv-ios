import SwiftUI

/// Vertical manga reader: streams chapter images with the headers the
/// plugin returned (Referer matters for most CDNs), prev/next chapter
/// navigation and progress saved to watch history.
struct MangaReaderView: View {
    let movie: Movie
    let pluginId: String
    let pluginName: String
    let serverName: String
    let episodes: [Episode]
    let startEpisode: Episode
    let initialStream: StreamInfo

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var history: WatchHistoryManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentEpisode: Episode
    @State private var stream: StreamInfo
    @State private var isLoadingChapter = false
    @State private var loadError: String?
    @State private var currentIndex: Int = 0

    init(movie: Movie, pluginId: String, pluginName: String, serverName: String,
         episodes: [Episode], startEpisode: Episode, initialStream: StreamInfo) {
        self.movie = movie
        self.pluginId = pluginId
        self.pluginName = pluginName
        self.serverName = serverName
        self.episodes = episodes
        self.startEpisode = startEpisode
        self.initialStream = initialStream
        _currentEpisode = State(initialValue: startEpisode)
        _stream = State(initialValue: initialStream)
    }

    private var currentPosition: Int {
        episodes.firstIndex { $0.id == currentEpisode.id } ?? 0
    }

    private var canGoPrevious: Bool { currentPosition > 0 }
    private var canGoNext: Bool { currentPosition < episodes.count - 1 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let loadError {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.amber)
                    Text(loadError)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button("Đóng") { dismiss() }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                }
                .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(stream.images.enumerated()), id: \.offset) { index, imageURL in
                            CachedAsyncImage(urlString: imageURL, headers: stream.headers, contentMode: .fit)
                                .frame(maxWidth: .infinity)
                                .onAppear {
                                    currentIndex = index
                                    saveProgress()
                                }
                        }
                        chapterNavButtons
                            .padding(.vertical, 28)
                    }
                }
                .overlay {
                    if isLoadingChapter {
                        ProgressView().tint(Theme.accent).scaleEffect(1.3)
                    }
                }
            }

            VStack {
                topBar
                Spacer()
            }
        }
        .statusBarHidden(true)
        .onAppear { saveProgress() }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Chap \(currentEpisode.name)  •  Trang \(min(currentIndex + 1, max(stream.images.count, 1)))/\(stream.images.count)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    private var chapterNavButtons: some View {
        HStack(spacing: 14) {
            Button {
                Task { await goToChapter(offset: -1) }
            } label: {
                Label("Chap trước", systemImage: "chevron.left")
            }
            .disabled(!canGoPrevious || isLoadingChapter)

            Button {
                Task { await goToChapter(offset: 1) }
            } label: {
                Label("Chap sau", systemImage: "chevron.right")
            }
            .disabled(!canGoNext || isLoadingChapter)
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
        .font(.system(size: 14, weight: .semibold, design: .rounded))
    }

    private func goToChapter(offset: Int) async {
        let target = currentPosition + offset
        guard episodes.indices.contains(target) else { return }
        let episode = episodes[target]
        isLoadingChapter = true
        defer { isLoadingChapter = false }
        do {
            let resolved = try await service.resolveMangaChapter(pluginId: pluginId, episode: episode)
            currentEpisode = episode
            stream = resolved
            currentIndex = 0
            saveProgress()
            Haptics.tap()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func saveProgress() {
        let record = HistoryRecord(
            pluginId: pluginId,
            pluginName: pluginName,
            isManga: true,
            movie: movie,
            serverName: serverName,
            episodeName: currentEpisode.name,
            episodeId: currentEpisode.id,
            streamURL: "",
            lastPosition: Double(currentIndex),
            duration: Double(max(stream.images.count, 1)),
            updatedAt: Date()
        )
        history.upsert(record)
    }
}
