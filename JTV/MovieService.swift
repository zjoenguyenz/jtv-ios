import Foundation

enum MovieServiceError: Error, LocalizedError {
    case pluginUnavailable
    case noURL
    case emptyDetail
    case unresolvedEpisode
    case timedOut

    var errorDescription: String? {
        switch self {
        case .pluginUnavailable: return "Plugin chưa sẵn sàng. Hãy đồng bộ nguồn plugin trong Cài đặt."
        case .noURL: return "Plugin không tạo được link dữ liệu."
        case .emptyDetail: return "Không tải được thông tin phim."
        case .unresolvedEpisode: return "Không tìm được link phát cho tập này."
        case .timedOut: return "Lấy link quá lâu (>45 giây). Kiểm tra mạng/VPN rồi bấm Thử lại."
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

    // MARK: - Session page cache

    /// Short-TTL in-memory cache for LIST / SEARCH / DETAIL page
    /// text (v1.22): back-navigation and tab re-entry used to
    /// refetch page 1 every time (0.9–2.4 s each, measured).
    /// Playback resolution is never cached (links expire), and
    /// plugin scripts / source lists are never cached here —
    /// sync freshness is PluginManager's domain.
    private struct CachedPage { let text: String; let at: Date }
    private var pageCache: [String: CachedPage] = [:]
    private let pageCacheLock = NSLock()
    private let pageCacheTTL: TimeInterval = 60

    private func fetchPage(_ url: String) async throws -> String {
        pageCacheLock.lock()
        let hit = pageCache[url]
        pageCacheLock.unlock()
        if let hit, Date().timeIntervalSince(hit.at) < pageCacheTTL {
            return hit.text
        }
        let text = try await Net.fetchText(url)
        pageCacheLock.lock()
        pageCache[url] = CachedPage(text: text, at: Date())
        if pageCache.count > 200 { pageCache.removeAll() }
        pageCacheLock.unlock()
        return text
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
        let text = try await fetchPage(url)
        return await engine.parseList(text: text)
    }

    func search(pluginId: String, keyword: String, page: Int) async throws -> ListPage {
        let engine = try await engine(for: pluginId)
        let filters = ListFilters()
        guard let url = await engine.urlForSearch(keyword: keyword, filtersJson: filters.jsonString(page: page)) else {
            throw MovieServiceError.noURL
        }
        let text = try await fetchPage(url)
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

    /// Stage 1 only: the detail record itself. Views render this
    /// immediately, then call `detailStreams` for the source list
    /// (v1.22 progressive detail — torrenthub's stage 2 measured
    /// +713 ms serial before anything could render).
    func detailMeta(pluginId: String, movieId: String) async throws -> DetailBundle {
        let engine = try await engine(for: pluginId)
        guard let url = await engine.urlForDetail(slug: movieId) else {
            throw MovieServiceError.noURL
        }
        let text = try await fetchPage(url)
        async let parsedDetail = engine.parseMovieDetail(text: text, url: url)
        async let parsedStream = engine.parseStream(text: text, url: url)
        let (detail, stream) = await (parsedDetail, parsedStream)
        guard let detail else { throw MovieServiceError.emptyDetail }
        return DetailBundle(detail: detail, detailStream: stream)
    }

    /// Stage 2 for two-stage plugins (torrenthub): a meta payload's
    /// detail carries ONE placeholder episode whose id starts with
    /// "jtvstreams:" — swap the real server list in. Returns the
    /// detail unchanged for single-stage plugins or when stage 2
    /// fails. Any other plugin is unaffected: none emits the prefix.
    func detailStreams(pluginId: String, movieId: String, detail: MovieDetail) async -> MovieDetail {
        guard let placeholder = detail.servers.first?.episodes.first,
              placeholder.id.hasPrefix("jtvstreams:") else { return detail }
        // Lane A (IMDb ids): fetch the streams from a
        // debrid-CONFIGURED Torrentio natively — the mechanism the
        // TV apps use, and the reason their torrent links feel
        // instant: cached torrents arrive with direct links in the
        // list itself. Tokens never enter the plugin/JS layer.
        if pluginId == "torrenthub", movieId.hasPrefix("tt"),
           let servers = await torrentioConfiguredStreams(imdbId: movieId), !servers.isEmpty {
            var resolved = detail
            resolved.servers = servers
            return resolved
        }
        guard let engine = try? await engine(for: pluginId),
              let stage2URL = await engine.urlForDetail(slug: placeholder.id),
              let stage2Text = try? await Net.fetchText(stage2URL),
              let stage2 = await engine.parseMovieDetail(text: stage2Text, url: stage2URL),
              !stage2.servers.isEmpty else { return detail }
        var resolved = detail
        resolved.servers = stage2.servers
        return resolved
    }

    func detail(pluginId: String, movieId: String) async throws -> DetailBundle {
        var bundle = try await detailMeta(pluginId: pluginId, movieId: movieId)
        bundle.detail = await detailStreams(pluginId: pluginId, movieId: movieId, detail: bundle.detail)
        return bundle
    }

    // MARK: - Torrentio (debrid-configured, native)

    /// The TV-style Torrentio config segment built from the user's
    /// debrid tokens, in the owner's preference order (TorBox →
    /// Premiumize → Real-Debrid). Empty when nothing is configured
    /// (bare Torrentio: hash-only entries).
    private func torrentioConfig() -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func enc(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value }
        var parts: [String] = []
        if !DebridTokens.torbox.isEmpty { parts.append("torbox=" + enc(DebridTokens.torbox)) }
        if !DebridTokens.premiumize.isEmpty { parts.append("premiumize=" + enc(DebridTokens.premiumize)) }
        if !DebridTokens.rd.isEmpty { parts.append("realdebrid=" + enc(DebridTokens.rd)) }
        return parts.joined(separator: "|")
    }

    private func torrentioConfiguredStreams(imdbId: String) async -> [EpisodeServer]? {
        let config = torrentioConfig()
        let base = config.isEmpty ? "https://torrentio.strem.fun" : "https://torrentio.strem.fun/" + config
        guard let url = URL(string: "\(base)/stream/movie/\(imdbId).json") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Net.desktopUA, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = json["streams"] as? [[String: Any]], !entries.isEmpty else { return nil }
        var episodes: [Episode] = []
        for entry in entries.prefix(40) {
            guard let hash = (entry["infoHash"] as? String)?.lowercased(), !hash.isEmpty else { continue }
            let title = (entry["title"] as? String) ?? ""
            let name = (entry["name"] as? String) ?? "Torrentio"
            let label = Self.torrentioLabel(name: name, title: title)
            if let direct = entry["url"] as? String, !direct.isEmpty {
                episodes.append(Episode(id: "jtvts:\(hash)|\(direct)", name: label))
            } else {
                episodes.append(Episode(id: "jtvhash:\(hash)", name: label))
            }
        }
        guard !episodes.isEmpty else { return nil }
        return [EpisodeServer(name: "Torrentio", episodes: episodes)]
    }

    static func torrentioLabel(name: String, title: String) -> String {
        let lines = title.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let file = lines.first ?? name
        var bits: [String] = []
        let hay = title.lowercased()
        for token in ["2160p", "1080p", "720p", "480p", "4k", "uhd", "bluray", "blu-ray", "web-dl", "webrip", "hdrip", "remux", "cam"] where hay.contains(token) {
            bits.append(token.uppercased())
            if bits.count >= 2 { break }
        }
        if let size = title.range(of: #"\d+(\.\d+)?\s?(GB|MB)"#, options: .regularExpression) {
            bits.append(String(title[size]))
        }
        if let seeds = title.range(of: #"👤\s*\d+"#, options: .regularExpression) {
            bits.append("🌱 " + title[seeds].dropFirst(1).trimmingCharacters(in: .whitespaces))
        }
        return bits.isEmpty ? file : file + "\n" + bits.joined(separator: " · ")
    }

    /// Chases one debrid-configured Torrentio resolve link. A real
    /// file URL means the provider had the torrent cached — play
    /// it now (the TV-fast path). A /videos/downloading_* or
    /// failed_* placeholder, or anything webpage-shaped, returns
    /// nil so the caller falls back to the native debrid chain
    /// with the entry's hash.
    private func chaseTorrentioResolve(_ urlString: String) async -> StreamInfo? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Net.desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let final = response.url else { return nil }
        let finalString = final.absoluteString
        let path = final.path.lowercased()
        if path.contains("/videos/downloading") || path.contains("/videos/failed") { return nil }
        if final.host == "torrentio.strem.fun" { return nil }
        if Self.looksLikeWebPage(finalString) { return nil }
        return StreamInfo(url: finalString, headers: [:], useCompatEngine: DebridResolver.needsCompatEngine(filename: final.lastPathComponent))
    }

    // MARK: - Embed prefetch (v1.22)

    /// One-shot cache for a dwell-prefetched EMBED resolution:
    /// for the sources whose chains end in the sniffing webview
    /// (123av, javhd, avdbapi), the chain itself (watch page →
    /// hops → embed page) is seconds of serial fetches that used
    /// to start at the play tap. The detail screen warms it while
    /// the user reads; the tap then consumes it. Only .embed
    /// outcomes are cached — a prefetched video URL could age,
    /// and the embed outcome is just a page URL + headers.
    private var prefetchedEmbeds: [String: (resolution: PlaybackResolution, at: Date)] = [:]
    private let prefetchLock = NSLock()

    func prefetchEmbedResolution(_ request: PlaybackRequest) {
        let key = request.pluginId + "|" + request.episode.id
        Task {
            guard let resolution = try? await self.resolveEpisode(request),
                  case .embed = resolution else { return }
            prefetchLock.lock()
            prefetchedEmbeds[key] = (resolution, Date())
            prefetchLock.unlock()
        }
    }

    private func consumePrefetchedEmbed(pluginId: String, target: String) -> PlaybackResolution? {
        let key = pluginId + "|" + target
        prefetchLock.lock()
        let hit = prefetchedEmbeds.removeValue(forKey: key)
        prefetchLock.unlock()
        guard let hit, Date().timeIntervalSince(hit.at) < 120 else { return nil }
        return hit.resolution
    }

    // MARK: - Playback resolution

    /// Resolves an episode tap following the plugin episode semantics:
    /// direct media -> native player; manga chapter API -> images;
    /// embed page -> plugin embed/detail parser, else webview sniffer.
    func resolveEpisode(_ request: PlaybackRequest) async throws -> PlaybackResolution {
        let pluginId = request.pluginId
        let target = request.episode.id
        guard !target.isEmpty else { throw MovieServiceError.unresolvedEpisode }

        if let prefetched = consumePrefetchedEmbed(pluginId: pluginId, target: target) {
            return prefetched
        }

        // Fast resume: a previously resolved direct stream.
        // (Skipped for torrenthub: debrid download links expire,
        // and re-minting one from the hash is cheap when cached.)
        if pluginId != "torrenthub", !request.knownStreamURL.isEmpty && MediaURL.isDirectMedia(request.knownStreamURL) {
            var headers = request.fallbackHeaders
            if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
            return .video(await markProxyIfNeeded(StreamInfo(url: request.knownStreamURL, headers: headers), pluginId: pluginId))
        }

        // Debrid torrent target (torrenthub): the episode id is an
        // info-hash, not a URL — the native debrid resolver turns
        // it into a direct file link (TorBox → Premiumize →
        // Real-Debrid), flagging containers AVPlayer cannot open
        // for the KSPlayer surface.
        if target.hasPrefix("jtvhash:") {
            let hash = String(target.dropFirst("jtvhash:".count))
            return .video(try await DebridResolver.resolve(hash: hash))
        }

        // Lane A entry from the debrid-configured Torrentio list
        // (v1.22): the episode carries a resolve link. Chase it
        // once — a cached torrent lands on the file URL directly;
        // a downloading/failed placeholder falls back to the
        // native chain with the entry's hash.
        if target.hasPrefix("jtvts:") {
            let payload = String(target.dropFirst("jtvts:".count))
            let parts = payload.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                if let chased = await chaseTorrentioResolve(parts[1]) {
                    return .video(chased)
                }
                return .video(try await DebridResolver.resolve(hash: parts[0]))
            }
        }

        // Direct media target.
        if MediaURL.isDirectMedia(target) {
            var headers = request.fallbackHeaders
            if headers.isEmpty { headers = await defaultHeaders(for: pluginId) }
            return .video(await markProxyIfNeeded(StreamInfo(url: target, headers: headers), pluginId: pluginId))
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
                return .video(await markProxyIfNeeded(resolved, pluginId: pluginId))
            }
            // Self-embed (123av's shape): the parser points back at
            // the very page we already fetched. Refetching it changes
            // nothing — hand it to the sniffing webview now, keeping
            // the plugin's step headers for the page load.
            if step.url == currentURL, let pageURL = URL(string: step.url) {
                var pageHeaders = step.headers
                if pageHeaders.isEmpty { pageHeaders = currentHeaders }
                return .embed(url: pageURL, headers: pageHeaders)
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

    /// Some playlists route their segments through a throwaway
    /// proxy host (streamxx's /__hls_proxy/…) that can be dead
    /// while the playlist itself still loads from an edge cache:
    /// AVPlayer then stalls on the first segment instead of
    /// failing, so the HLS-proxy rescue retry never engages. Peek
    /// at the playlist; when it uses that wrapper, mark the stream
    /// so the player starts through the rescue proxy immediately
    /// (the proxy unwraps the segment URLs itself).
    ///
    /// Film4K is marked unconditionally: its segments are fMP4
    /// files wrapped in PNG images (the TV app's v1.6.4 round
    /// closed its Film4K saga — the service itself is healthy,
    /// just slow through the tunnel, and the app's fetch layer is
    /// already patient). A wrapped segment makes AVPlayer stall
    /// rather than fail, which is exactly the case the plain-first
    /// retry cannot rescue; starting through the loader (which
    /// strips the wrappers) is the reliable order, and v1.8's
    /// proxied→plain fallback covers the reverse if ever needed.
    /// Per-host verdict cache (v1.22): the probe below downloads
    /// the whole playlist just to grep for the wrapper — measured
    /// 1.5–2.0 s on sextop1's 80 KB playlist, paid on EVERY tap for
    /// a wrapper its playlists never contain. Only the streamxx
    /// family produces the wrapper, so a host's first successful
    /// probe settles the question for the rest of the session.
    private static var proxyVerdicts: [String: Bool] = [:]
    private static let proxyVerdictLock = NSLock()

    private func markProxyIfNeeded(_ stream: StreamInfo, pluginId: String) async -> StreamInfo {
        if pluginId == "film4k", stream.url.lowercased().contains(".m3u8") {
            var marked = stream
            marked.requiresProxy = true
            return marked
        }
        guard stream.url.lowercased().contains(".m3u8") else { return stream }
        let host = URL(string: stream.url)?.host ?? ""
        if !host.isEmpty {
            Self.proxyVerdictLock.lock()
            let cached = Self.proxyVerdicts[host]
            Self.proxyVerdictLock.unlock()
            if let cached {
                guard cached else { return stream }
                var marked = stream
                marked.requiresProxy = true
                return marked
            }
        }
        guard let text = try? await Net.fetchText(stream.url, headers: stream.headers) else { return stream }
        let verdict = text.contains("__hls_proxy/")
        if !host.isEmpty {
            Self.proxyVerdictLock.lock()
            Self.proxyVerdicts[host] = verdict
            Self.proxyVerdictLock.unlock()
        }
        guard verdict else { return stream }
        var marked = stream
        marked.requiresProxy = true
        return marked
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
