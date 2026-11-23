import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var plugins: PluginManager

    @State private var query = ""
    @State private var submittedQuery = ""
    @State private var recentQueries: [String] = []
    @State private var path: [AppRoute] = []

    private let recentKey = "jtv_recent_searches"
    private var pluginId: String { plugins.activePlugin?.id ?? "" }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.clear.jtvBackground()

                if plugins.visiblePlugins.isEmpty {
                    ContentUnavailableView("Chưa có nguồn plugin",
                                           systemImage: "puzzlepiece.extension",
                                           description: Text("Đồng bộ nguồn plugin trong Cài đặt trước."))
                } else if submittedQuery.isEmpty {
                    suggestions
                } else {
                    SearchResultsView(query: submittedQuery, pluginId: pluginId)
                }
            }
            .navigationTitle("Tìm kiếm")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Tìm phim, truyện…")
            .onSubmit(of: .search) { submit() }
            .navigationDestination(for: AppRoute.self) { route in
                switch route {
                case .movie(let movieRoute):
                    MovieDetailView(pluginId: movieRoute.pluginId, movie: movieRoute.movie, autoResume: movieRoute.autoResume)
                case .category(let categoryRoute):
                    CategoryDetailView(pluginId: categoryRoute.pluginId, slug: categoryRoute.slug,
                                       title: categoryRoute.title, initialFilters: categoryRoute.filters)
                case .search(let searchRoute):
                    SearchResultsView(query: searchRoute.keyword, pluginId: searchRoute.pluginId)
                case .actor(let actorRoute):
                    ActorView(pluginId: actorRoute.pluginId, name: actorRoute.name, route: actorRoute.route)
                }
            }
            .onChange(of: path) { _, _ in NavSanitizer.sanitize(&path) }
            .onAppear {
                recentQueries = UserDefaults.standard.stringArray(forKey: recentKey) ?? []
            }
        }
    }

    private var suggestions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let active = plugins.activePlugin {
                    HStack(spacing: 8) {
                        CachedAsyncImage(urlString: active.manifest.iconUrl)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text("Tìm trong nguồn \(active.manifest.name)")
                            .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textDim)
                    }
                }
                if !recentQueries.isEmpty {
                    SectionHeader(title: "Tìm gần đây")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                        ForEach(recentQueries, id: \.self) { term in
                            Button {
                                query = term
                                submittedQuery = term
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 11))
                                    Text(term).lineLimit(1)
                                }
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .glassCard(cornerRadius: 12)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("Xoá lịch sử tìm kiếm", role: .destructive) {
                        recentQueries = []
                        UserDefaults.standard.removeObject(forKey: recentKey)
                    }
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                } else {
                    Text("Nhập tên phim hoặc truyện rồi nhấn Tìm trên bàn phím.")
                        .font(.system(size: 13.5, design: .rounded))
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(16)
        }
    }

    private func submit() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        submittedQuery = term
        var list = recentQueries.filter { $0.lowercased() != term.lowercased() }
        list.insert(term, at: 0)
        recentQueries = Array(list.prefix(10))
        UserDefaults.standard.set(recentQueries, forKey: recentKey)
    }
}

// MARK: - Reusable search results (also used for cast-name search)

struct SearchResultsView: View {
    let query: String
    let pluginId: String

    @EnvironmentObject private var service: MovieService
    @EnvironmentObject private var favorites: FavoritesManager

    @State private var items: [Movie] = []
    @State private var page = 1
    @State private var totalPages = 1
    @State private var isLoading = false
    @State private var isLoadingMore = false
    @State private var loadError: String?
    @State private var didLoad = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ZStack {
            Color.clear.jtvBackground()

            if isLoading && items.isEmpty {
                ProgressView().tint(Theme.accent).scaleEffect(1.3)
            } else if let loadError, items.isEmpty {
                ContentUnavailableView("Tìm kiếm thất bại", systemImage: "wifi.exclamationmark",
                                       description: Text(loadError))
            } else if items.isEmpty && didLoad {
                ContentUnavailableView("Không tìm thấy kết quả", systemImage: "magnifyingglass",
                                       description: Text("Không có kết quả cho “\(query)”."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { movie in
                            NavigationLink(value: AppRoute.movie(MovieRoute(pluginId: pluginId, movie: movie))) {
                                MovieGridCell(movie: movie)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    favorites.toggle(pluginId: pluginId, movie: movie)
                                } label: {
                                    Label(
                                        favorites.isFavorite(pluginId: pluginId, movieId: movie.id)
                                            ? "Bỏ yêu thích" : "Thêm vào yêu thích",
                                        systemImage: "heart"
                                    )
                                }
                            }
                            .onAppear {
                                if movie.id == items.last?.id {
                                    Task { await loadMore() }
                                }
                            }
                        }
                    }
                    .padding(16)

                    if isLoadingMore {
                        ProgressView().tint(Theme.accent).padding(.bottom, 24)
                    }
                }
            }
        }
        .navigationTitle(query)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: query + pluginId) {
            didLoad = false
            items = []
            await reload()
            didLoad = true
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        page = 1
        do {
            let result = try await service.search(pluginId: pluginId, keyword: query, page: 1)
            items = result.items
            totalPages = max(result.pagination.totalPages, 1)
            page = result.pagination.currentPage
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, page < totalPages else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let next = page + 1
            let result = try await service.search(pluginId: pluginId, keyword: query, page: next)
            let known = Set(items.map { $0.id })
            items.append(contentsOf: result.items.filter { !known.contains($0.id) })
            page = result.pagination.currentPage
            totalPages = max(result.pagination.totalPages, totalPages)
        } catch {}
    }
}
