import Foundation

enum MovieServiceError: Error, LocalizedError {
    case pluginUnavailable
    case noURL
    case emptyDetail
    case unresolvedEpisode

    var errorDescription: String? {
        switch self {
        case .pluginUnavailable: return "Plugin chưa sẵn sàng. Hãy đồng bộ nguồn plugin trong Cài đặt."
        case .noURL: return "Plugin không tạo được link dữ liệu."
        case .emptyDetail: return "Không tải được thông tin phim."
        case .unresolvedEpisode: return "Không tìm được link phát cho tập này."
        }
    }
}

/// Loads catalog data through the plugin contract and resolves episode
/// play targets into native streams, manga chapters or embed pages.
final class MovieService: ObservableObject {
    let manager: PluginManager

    init(manager: PluginManager) {
        self.manager = manager
    }

    private func engine(for pluginId: String) async throws -> PluginEngine {
        guard let engine = await manager.engine(for: pluginId) else {
            throw MovieServiceError.pluginUnavailable
        }
        return engine
    }

    private func manifest(for pluginId: String) async -> PluginManifest? {
        await manager.installedPlugin(id: pluginId)?.manifest
    }

    /// Embed-page shapes a parser may hand back as its final answer.
    /// Deliberately narrow: disguised stream files (.vl) and signed
    /// extension-less media URLs must NOT match.
    static func looksLikeWebPage(_ urlString: String) -> Bool {
        guard let path = URL(string: urlString)?.path.lowercased() else { return false }
        return path.contains("/e/") || path.contains("/embed") || path.contains("/play/")
            || path.hasSuffix(".html") || path.hasSuffix(".htm") || path.hasSuffix(".php")
    }

    func defaultHeaders(for pluginId: String) async -> [String: String] {
        var headers = ["User-Agent": Net.desktopUA]
        if let base = await manifest(for: pluginId)?.baseUrl, !base.isEmpty {
            headers["Referer"] = base.hasSuffix("/") ? base : base + "/"
        }
        return headers
    }

    // MARK: - Discovery

    func homeSections(pluginId: String) async -> [HomeSection] {
        guard let engine = try? await engine(for: pluginId) else { return [] }
        return await engine.homeSections()
    }

    func primaryCategories(pluginId: String) async -> [NameSlug] {
        guard let engine = try? await engine(for: pluginId) else { return [] }
        return await engine.primaryCategories()
    }

    func filterConfig(pluginId: String) async -> FilterConfig {
        guard let engine = try? await engine(for: pluginId) else { return FilterConfig() }
        return await engine.filterConfig()
    }

    // MARK: - Lists & search

    func list(pluginId: String, slug: String, filters: ListFilters, page: Int) async throws -> ListPage {
        let engine = try await engine(for: pluginId)
        guard let url = await engine.urlForList(slug: slug, filtersJson: filters.jsonString(page: page)) else {
            throw MovieServiceError.noURL
        }
        let text = try await Net.fetchText(url)
        return await engine.parseList(text: text)
    }

    func search(pluginId: String, keyword: String, page: Int) async throws -> ListPage {
        let engine = try await engine(for: pluginId)
        let filters = ListFilters()
        guard let url = await engine.urlForSearch(keyword: keyword, filtersJson: filters.jsonString(page: page)) else {
            throw MovieServiceError.noURL
        }
        let text = try await Net.fetchText(url)
        return await engine.parseSearch(text: text)
    }

    // MARK: - Filter option lists

    func categories(pluginId: String) async -> [NameSlug] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForCategories(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseCategories(text: text)
    }

    func countries(pluginId: String) async -> [NameValue] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForCountries(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseCountries(text: text)
    }

    func years(pluginId: String) async -> [NameValue] {
        guard let engine = try? await engine(for: pluginId),
              let url = await engine.urlForYears(),
              let text = try? await Net.fetchText(url) else { return [] }
        return await engine.parseYears(text: text)
    }

    // MARK: - Detail

    struct DetailBundle {
        var detail: MovieDetail
        /// Stream parsed from the detail response itself (first-episode
        /// stream for API-style plugins; may be empty).
        var detailStream: StreamInfo
    }

    func detail(pluginId: String, movieId: String) async throws -> DetailBundle {
        let engine = try await engine(for: pluginId)
        guard let url = await engine.urlForDetail(slug: movieId) else {
            throw MovieServiceError.noURL
        }
        let text = try await Net.fetchText(url)
        async let parsedDetail = engine.parseMovieDetail(text: text, url: url)
        async let parsedStream = engine.parseStream(text: text, url: url)
        let (detail, stream) = await (parsedDetail, parsedStream)
        guard let detail else { throw MovieServiceError.emptyDetail }
        return DetailBundle(detail: detail, detailStream: stream)
    }

    // MARK: - Playback resolution

    /// Resolves an episode tap following the plugin episode semantics:
    /// direct media -> native player; manga chapter API -> images;
    /// embed page -> plugin embed/detail parser, else webview sniffer.
    func resolveEpisode(_ request: PlaybackRequest) async throws -> PlaybackResolution {
        let pluginId = request.pluginId
        let target = request.episode.id
        guard !target.isEmpty else { throw MovieServiceError.unresolvedEpisode }

        // Fast resume: a previously resolved direct stream.
        if !request.knownStreamURL.isEmpty && MediaURL.isDirectMedia(request.knownStreamURL) {
            var headers = request.fallbackHeaders
            if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
            return .video(StreamInfo(url: request.knownStreamURL, headers: headers))
        }

        // Direct media target.
        if MediaURL.isDirectMedia(target) {
            var headers = request.fallbackHeaders
            if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
            return .video(StreamInfo(url: target, headers: headers))
        }

        guard let engine = try? await engine(for: pluginId) else {
            throw MovieServiceError.pluginUnavailable
        }

        // Manga chapter: fetch the chapter API and parse its image list.
        if request.isManga {
            let text = try await Net.fetchText(target)
            let stream = await engine.parseStream(text: text, url: target)
            if !stream.images.isEmpty {
                var resolved = stream
                if resolved.headers.isEmpty { resolved.headers = await defaultHeaders(for: pluginId) }
                return .manga(resolved)
            }
            throw MovieServiceError.unresolvedEpisode
        }

        // Embed chain: plugins resolve in hops — a parser returns
        // isEmbed=true plus the NEXT url (njav: watch page → /jm/ →
        // player page → signed m3u8; vlxx: a POST config; sextop1:
        // a player-API config). Follow the chain like the reference
        // resolver does: fetch each hop (POST when the config carries
        // a postBody) and re-parse, until a hop yields a direct
        // stream (isEmbed=false), an image set, or the chain runs
        // out. The old single-pass code handed the first hop's page
        // URL to AVPlayer, which failed instantly.
        var currentURL = target
        var currentHeaders = await defaultHeaders(for: pluginId)
        var payload = try await Net.fetchText(currentURL, headers: currentHeaders)
        var lastEmbedURL = target
        for _ in 0..<4 {
            var step = await engine.parseEmbed(html: payload, url: currentURL)
            if step == nil || step?.hasPlayableURL != true {
                let parsed = await engine.parseStream(text: payload, url: currentURL)
                if parsed.hasPlayableURL || !parsed.images.isEmpty { step = parsed }
            }
            guard let step, step.hasPlayableURL || !step.images.isEmpty else { break }
            if !step.images.isEmpty {
                var resolved = step
                if resolved.headers.isEmpty { resolved.headers = currentHeaders }
                return .manga(resolved)
            }
            if !step.isEmbed || MediaURL.isDirectMedia(step.url) {
                // A web page is never a video: some plugins finish
                // their chain at an embed page marked isEmbed=false
                // (javhd → cloudwish /e/…). AVPlayer fails on those
                // instantly; the sniffing webview is the right home.
                if !MediaURL.isDirectMedia(step.url), Self.looksLikeWebPage(step.url),
                   let pageURL = URL(string: step.url) {
                    var pageHeaders = step.headers
                    if pageHeaders.isEmpty { pageHeaders = currentHeaders }
                    return .embed(url: pageURL, headers: pageHeaders)
                }
                var resolved = step
                if resolved.headers.isEmpty { resolved.headers = currentHeaders }
                return .video(resolved)
            }
            // Follow the hop.
            lastEmbedURL = step.url
            currentURL = step.url
            if !step.headers.isEmpty {
                currentHeaders = (await defaultHeaders(for: pluginId)).merging(step.headers) { _, new in new }
            }
            if let body = step.postBody, !body.isEmpty {
                payload = try await Net.fetchTextPOST(currentURL, body: body, headers: currentHeaders)
            } else {
                payload = try await Net.fetchText(currentURL, headers: currentHeaders)
            }
        }

        // Last resort: open the embed in the sniffing webview.
        guard let url = URL(string: lastEmbedURL) else { throw MovieServiceError.unresolvedEpisode }
        return .embed(url: url, headers: await defaultHeaders(for: pluginId))
    }

    /// Resolves one manga chapter (used by the reader's prev/next).
    func resolveMangaChapter(pluginId: String, episode: Episode) async throws -> StreamInfo {
        guard let engine = try? await engine(for: pluginId) else {
            throw MovieServiceError.pluginUnavailable
        }
        let text = try await Net.fetchText(episode.id)
        let stream = await engine.parseStream(text: text, url: episode.id)
        guard !stream.images.isEmpty else { throw MovieServiceError.unresolvedEpisode }
        var resolved = stream
        if resolved.headers.isEmpty { resolved.headers = await defaultHeaders(for: pluginId) }
        return resolved
    }
}
