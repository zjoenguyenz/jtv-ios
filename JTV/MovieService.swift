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
        case .timedOut: return "Lấy link quá lâu. Kiểm tra mạng/VPN rồi bấm Thử lại."
        }
    }
}

/// Loads catalog data through the plugin contract and resolves episode
/// play targets into native streams, manga chapters or embed pages.
/// MainActor-isolated (Swift 6): it is a UI-facing store; its caches
/// were already lock-guarded, and its heavy work awaits out to
/// non-isolated helpers (Net, PluginEngine, DebridResolver).
@MainActor
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
        // Swift 6: scoped withLock replaces lock()/unlock()
        // pairs in async contexts (see Cache.swift note).
        let hit = pageCacheLock.withLock { pageCache[url] }
        if let hit, Date().timeIntervalSince(hit.at) < pageCacheTTL {
            return hit.text
        }
        let text = try await Net.fetchText(url)
        pageCacheLock.withLock {
            pageCache[url] = CachedPage(text: text, at: Date())
            if pageCache.count > 200 { pageCache.removeAll() }
        }
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
        // v1.22.2: stage 2 goes through the PLUGIN only — the exact
        // v1.21 path. The v1.22 native debrid-configured Torrentio
        // fetch (jtvts: episodes + resolve-link chase) was removed
        // in the same restoration as the DebridResolver chain: it
        // was never device-proven, while the plugin path was.
        guard let engine = try? await engine(for: pluginId),
              let stage2URL = await engine.urlForDetail(slug: placeholder.id),
              let stage2Text = try? await Net.fetchText(stage2URL),
              let stage2 = await engine.parseMovieDetail(text: stage2Text, url: stage2URL),
              !stage2.servers.isEmpty else { return detail }
        var resolved = detail
        resolved.servers = stage2.servers
        return await mergeMediaFusion(pluginId: pluginId, movieId: movieId, detail: resolved)
    }

    /// v1.22.5: MediaFusion merge (owner request — the same
    /// second torrent gateway the Sony app runs beside
    /// Torrentio). When the owner has pasted his MediaFusion
    /// manifest URL in Settings, a torrenthub detail for an
    /// IMDb-id title gains a "MediaFusion" server: MediaFusion
    /// answers with direct per-provider links (its responses
    /// carry no infoHash), quality-sorted like the plugin's own
    /// list. Strictly additive — no URL configured, a failed
    /// fetch, or an empty answer leaves the detail exactly as
    /// the plugin made it. The manifest URL is a bearer
    /// credential: it lives only in UserDefaults, never logged.
    func mergeMediaFusion(pluginId: String, movieId: String, detail: MovieDetail) async -> MovieDetail {
        guard pluginId == "torrenthub", movieId.hasPrefix("tt"),
              let base = MediaFusion.baseURL else { return detail }
        let url = "\(base)/stream/movie/\(movieId).json"
        guard let text = try? await Net.fetchText(url) else { return detail }
        let episodes = MediaFusion.parseStreams(text: text)
        guard !episodes.isEmpty else { return detail }
        var merged = detail
        merged.servers.append(EpisodeServer(name: "MediaFusion", episodes: episodes))
        return merged
    }

    func detail(pluginId: String, movieId: String) async throws -> DetailBundle {
        var bundle = try await detailMeta(pluginId: pluginId, movieId: movieId)
        bundle.detail = await detailStreams(pluginId: pluginId, movieId: movieId, detail: bundle.detail)
        return bundle
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
            prefetchLock.withLock { prefetchedEmbeds[key] = (resolution, Date()) }
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
        // it into a direct file link (Real-Debrid → TorBox →
        // Premiumize), flagging containers AVPlayer cannot open
        // for the KSPlayer surface.
        if target.hasPrefix("jtvhash:") {
            let hash = String(target.dropFirst("jtvhash:".count))
            return .video(try await DebridResolver.resolve(hash: hash))
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
        // streamxx delivery probe (2026-11-18): the operator's
        // newer uploads are a progressive MP4 served AT the
        // /main.m3u8 address (content-type video/mp4, range
        // requests honored), with no HLS backup in the segment
        // store. Synthesis declines those (segment 0 is a 404)
        // and the HLS transports then stall ~30 s on a file that
        // was never a playlist — the dead tap the owner reported.
        // Pick the path by measurement instead: backup present →
        // today's synthesis path, untouched (the proxy verdict
        // below never affected streamxx playback — synthesis
        // outranks the proxy ladder — and its full-body fetch is
        // pure cost here, worst on the MP4 titles where it pulls
        // the movie down as "text"); backup missing + the origin
        // answers as a media file → the compat engine, which
        // sniffs the real container. Any probe doubt → the
        // stream passes through unchanged.
        if let url = URL(string: stream.url), let id = PlaylistSynthesizer.streamxxID(from: url) {
            if await PlaylistSynthesizer.backupExists(streamID: id) { return stream }
            if await Self.originServesProgressiveFile(url, headers: stream.headers) {
                var direct = stream
                direct.useCompatEngine = true
                return direct
            }
            return stream
        }
        guard stream.url.lowercased().contains(".m3u8") else { return stream }
        let host = URL(string: stream.url)?.host ?? ""
        if !host.isEmpty {
            let cached = Self.proxyVerdictLock.withLock { Self.proxyVerdicts[host] }
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
            Self.proxyVerdictLock.withLock { Self.proxyVerdicts[host] = verdict }
        }
        guard verdict else { return stream }
        var marked = stream
        marked.requiresProxy = true
        return marked
    }

    /// Range-probes a URL's first bytes: true when the origin
    /// answers with a media file (MP4 family) rather than a
    /// playlist. Only ever called on embed.streamxx.net URLs,
    /// whose server honors Range (measured 206). Any doubt →
    /// false, and today's path carries on unchanged.
    private static func originServesProgressiveFile(_ url: URL, headers: [String: String]) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        // Set AFTER the caller's headers: a stray Range in them
        // must not widen the probe (gate MINOR, 2026-11-18).
        req.setValue("bytes=0-15", forHTTPHeaderField: "Range")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
        if let mime = http.mimeType, mime.hasPrefix("video/") { return true }
        // ftyp box at bytes 4-7 (isom / mp42 / avc1 …): a media
        // file whatever the label says. A playlist starts '#'.
        guard data.count >= 8 else { return false }
        let head = [UInt8](data.prefix(16))
        if head[0] == 0x23 { return false }
        return head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 && head[7] == 0x70
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

// MARK: - MediaFusion (v1.22.5)

/// Parser + settings for the owner's MediaFusion gateway. The
/// manifest URL is configured by the owner at
/// mediafusion.elfhosted.com/configure (his providers, cached
/// only) and pasted into Settings; it is a bearer credential —
/// stored only in UserDefaults, never logged, never sent
/// anywhere except the gateway itself. MediaFusion stream
/// responses carry NO infoHash: every entry is a direct
/// per-provider link, so episodes keep the URL as their id
/// (the same shape as the torrenthub plugin's direct entries).
enum MediaFusion {
    static let urlKey = "jtv_mediafusion_url"

    static var baseURL: String? {
        let raw = UserDefaults.standard.string(forKey: urlKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return nil }
        var value = raw
        if value.hasPrefix("stremio://") {
            value = "https://" + String(value.dropFirst("stremio://".count))
        }
        if value.hasSuffix("/manifest.json") {
            value = String(value.dropLast("/manifest.json".count))
        }
        if value.hasSuffix("/") { value = String(value.dropLast()) }
        guard value.hasPrefix("http") else { return nil }
        return value
    }

    static func parseStreams(text: String) -> [Episode] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = root["streams"] as? [[String: Any]] else { return [] }
        var parsed: [(episode: Episode, rank: Int, seeds: Int, sizeMB: Double)] = []
        for stream in streams {
            let name = stream["name"] as? String ?? ""
            let title = stream["title"] as? String ?? ""
            let hints = stream["behaviorHints"] as? [String: Any]
            let filename = (hints?["filename"] as? String)
                ?? title.components(separatedBy: "\n").first
                ?? ""
            let provider: String
            let lowered = name.lowercased()
            if lowered.contains("premiumize") || name.contains("PM") { provider = "PM" }
            else if lowered.contains("torbox") || name.contains("TB") { provider = "TB" }
            else if lowered.contains("real-debrid") || lowered.contains("realdebrid") || name.contains("RD") { provider = "RD" }
            else { provider = "MF" }
            let haystack = (name + " " + title + " " + filename).lowercased()
            // v1.22.8: 1440p and FHD join the 1080 tier (the plugin
            // ranks 1440p a half-step above 1080p; here the Int
            // scale ties them and the seed count decides, which is
            // the owner's stated tiebreak).
            let rank = (haystack.contains("2160") || haystack.contains("4k") || haystack.contains("uhd")) ? 4
                : (haystack.contains("1440") || haystack.contains("1080") || haystack.contains("fhd")) ? 3
                : haystack.contains("720") ? 2
                : haystack.contains("480") ? 1 : 0
            let seeds = intAfter("👤", in: title)
            let sizeMB = sizeInMB(title)
            var label = provider
            if !filename.isEmpty { label += " · " + filename }
            if sizeMB > 0 { label += " · " + formatSize(sizeMB) }
            if seeds > 0 { label += " · 👤 \(seeds)" }
            if let url = stream["url"] as? String, !url.isEmpty {
                parsed.append((Episode(id: url, name: label, slug: url), rank, seeds, sizeMB))
            } else if let hash = (stream["infoHash"] as? String)?.lowercased(), !hash.isEmpty {
                let id = "jtvhash:" + hash
                parsed.append((Episode(id: id, name: label, slug: id), rank, seeds, sizeMB))
            }
        }
        parsed.sort { a, b in
            if a.rank != b.rank { return a.rank > b.rank }
            if a.seeds != b.seeds { return a.seeds > b.seeds }
            return a.sizeMB > b.sizeMB
        }
        return parsed.prefix(15).map { $0.episode }
    }

    private static func intAfter(_ marker: String, in text: String) -> Int {
        guard let range = text.range(of: marker) else { return 0 }
        let digits = text[range.upperBound...].drop { !$0.isNumber }.prefix { $0.isNumber }
        return Int(digits) ?? 0
    }

    private static func sizeInMB(_ text: String) -> Double {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(GB|GiB|MB|MiB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let valueRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let value = Double(text[valueRange]) else { return 0 }
        let unit = text[unitRange]
        return (unit == "GB" || unit == "GiB") ? value * 1024 : value
    }

    private static func formatSize(_ sizeMB: Double) -> String {
        sizeMB >= 1024
            ? String(format: "%.2f GB", sizeMB / 1024)
            : String(format: "%.0f MB", sizeMB)
    }
}
