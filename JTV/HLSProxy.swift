import Foundation
import AVFoundation

/// HLS rescue layer for CDNs that disguise streams as images.
///
/// Some hosts (e.g. RapPhim's cloud152/nebula packaging) serve the
/// playlist itself as `1080p/playlist.jpg` with Content-Type
/// image/jpeg, and the fMP4 segments as .jpg files, also image/jpeg.
/// Android/ExoPlayer sniffs the #EXTM3U magic and plays anyway;
/// AVPlayer trusts the declared type and refuses the asset outright.
///
/// This loader serves the stream to AVPlayer through a custom URL
/// scheme instead: it fetches every resource itself (URLSession does
/// not care about the declared type), rewrites playlist URIs so all
/// nested resources come back through the loader, sniffs binary
/// payloads, and reports correct content types to AVFoundation.
///
/// It is used as a FALLBACK only: the player first tries the plain
/// URL, and only a failed AVPlayerItem triggers the proxied retry —
/// sources that already play natively are never touched.
final class HLSProxyLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "jtvhls"

    private let headers: [String: String]
    private let session: URLSession
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private let lock = NSLock()
    /// Playlists already rewritten, by requested URL. Only playlists
    /// are cached (they are tiny); segments are fetched per request
    /// and never retained — a whole movie of segments would exhaust
    /// memory.
    private var cache: [String: (data: Data, contentType: String)] = [:]

    init(headers: [String: String]) {
        self.headers = headers
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
        super.init()
    }

    // MARK: - URL wrapping
    //
    // The original URL travels base64url-encoded in the query: pure
    // [A-Za-z0-9_-] characters, so no percent-encoding ambiguity can
    // creep in across AVFoundation's URL handling.

    static func proxiedURL(for url: URL) -> URL? {
        let b64 = Data(url.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(scheme)://h/?u=\(b64)")
    }

    static func originalURL(from proxied: URL) -> URL? {
        guard let comps = URLComponents(url: proxied, resolvingAgainstBaseURL: false),
              var b64 = comps.queryItems?.first(where: { $0.name == "u" })?.value else { return nil }
        b64 = b64.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return URL(string: string)
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              requestURL.scheme == Self.scheme,
              let original = Self.originalURL(from: requestURL) else { return false }

        let key = original.absoluteString
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached {
            respond(loadingRequest, data: cached.data, contentType: cached.contentType)
            return true
        }

        var request = URLRequest(url: original)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            self.tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
            self.lock.unlock()
            if loadingRequest.isFinished { return }
            if let error {
                loadingRequest.finishLoading(with: error)
                return
            }
            guard let data, let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                loadingRequest.finishLoading(with: URLError(.badServerResponse))
                return
            }
            let finalURL = http.url ?? original
            let served = self.prepare(data: data, finalURL: finalURL)
            // Cache only complete VOD playlists; live playlists must
            // be re-fetched on every pass, segments are never kept.
            let isPlaylist = served.contentType == "com.apple.mpegurl"
            if isPlaylist && served.data.range(of: Data("#EXT-X-ENDLIST".utf8)) != nil {
                self.lock.lock()
                self.cache[key] = served
                self.lock.unlock()
            }
            if loadingRequest.isFinished { return }
            self.respond(loadingRequest, data: served.data, contentType: served.contentType)
        }
        lock.lock()
        tasks[ObjectIdentifier(loadingRequest)] = task
        lock.unlock()
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        lock.lock()
        let task = tasks.removeValue(forKey: ObjectIdentifier(loadingRequest))
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Serving

    /// Classifies a fetched body: playlists are rewritten so every
    /// nested URI routes back through this loader; binaries are
    /// sniffed and re-typed honestly.
    private func prepare(data: Data, finalURL: URL) -> (data: Data, contentType: String) {
        var data = data
        // Some CDNs wrap each segment in a complete tiny PNG (a real
        // image header + IEND, then the actual media bytes): VSMOV's
        // TS segments and Film4K's fMP4 segments both do this. Strip
        // the wrapper or AVFoundation chokes on the garbage prefix.
        if Self.hasPNGMagic(data), let stripped = Self.stripPNGWrapper(data) {
            data = stripped
        }
        if Self.looksLikePlaylist(data),
           let text = String(data: data, encoding: .utf8) {
            let rewritten = Self.rewritePlaylist(text, base: finalURL)
            return (Data(rewritten.utf8), "com.apple.mpegurl")
        }
        return (data, Self.sniffContentType(data: data, url: finalURL))
    }

    static func hasPNGMagic(_ data: Data) -> Bool {
        data.count >= 8 && data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    /// Returns the media payload after a PNG wrapper, or nil when no
    /// confident media start is found. Tries, in order: the bytes
    /// right after the PNG's IEND chunk; the first MPEG-TS sync
    /// pattern (0x47 at i, i+188, i+376); an fMP4 box type (ftyp/
    /// styp) backed up to its 4-byte size field.
    static func stripPNGWrapper(_ data: Data) -> Data? {
        let window = min(data.count, 8192)
        // 1) IEND terminator: 00 00 00 00 "IEND" AE 42 60 82
        let iend = Data([0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        if let range = data.range(of: iend, in: 0..<window) {
            let start = range.upperBound
            if start < data.count { return data.subdata(in: start..<data.count) }
        }
        // 2) TS sync pattern
        if data.count > 564 {
            var i = 1
            let limit = min(data.count - 565, window)
            while i < limit {
                if data[i] == 0x47 && data[i + 188] == 0x47 && data[i + 376] == 0x47 && data[i + 564] == 0x47 {
                    return data.subdata(in: i..<data.count)
                }
                i += 1
            }
        }
        // 3) fMP4 box
        for marker in ["styp", "ftyp"] {
            if let range = data.range(of: Data(marker.utf8), in: 0..<window), range.lowerBound >= 4 {
                let start = range.lowerBound - 4
                if start > 0 && start < data.count { return data.subdata(in: start..<data.count) }
            }
        }
        return nil
    }

    private func respond(_ request: AVAssetResourceLoadingRequest, data: Data, contentType: String) {
        if let info = request.contentInformationRequest {
            info.contentType = contentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return
        }
        let requestedOffset = Int(dataRequest.requestedOffset)
        // requestedLength can arrive as Int.max ("to the end") —
        // cap it before any addition so the arithmetic cannot overflow.
        let cappedLength = min(dataRequest.requestedLength, data.count)
        let start = min(max(requestedOffset, Int(dataRequest.currentOffset)), data.count)
        let end = min(data.count, requestedOffset + cappedLength)
        if start < end {
            dataRequest.respond(with: data.subdata(in: start..<end))
        }
        if Int(dataRequest.currentOffset) >= end {
            request.finishLoading()
        }
    }

    // MARK: - Playlist rewriting

    static func looksLikePlaylist(_ data: Data) -> Bool {
        let head = data.prefix(512)
        guard let text = String(data: head, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U")
    }

    static func rewritePlaylist(_ text: String, base: URL) -> String {
        var out: [String] = []
        out.reserveCapacity(1024)
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                out.append(rewriteTagLine(line, base: base))
            } else if line.isEmpty {
                out.append(rawLine)
            } else {
                out.append(wrap(line, base: base))
            }
        }
        return out.joined(separator: "\n")
    }

    private static func wrap(_ uri: String, base: URL) -> String {
        guard var absolute = URL(string: uri, relativeTo: base)?.absoluteURL,
              absolute.scheme == "http" || absolute.scheme == "https" else { return uri }
        // streamxx-style HLS proxies wrap the real file URL as
        // /__hls_proxy/<base64>. When that proxy dies, the playlist
        // still loads (edge cache) but every segment returns 502 —
        // while the wrapped origin file stays publicly fetchable
        // (topxx, verified 2026-11-14: HTTP 200, full size, valid
        // TS, with NO headers at all and with AVPlayer's own user
        // agent). Serve the unwrapped URL DIRECTLY in the
        // rewritten playlist and let AVPlayer fetch the segment
        // itself. Routing these segments back through this loader
        // (the pre-v1.11 behaviour) never once played on the
        // user's device across four builds, while every other
        // part of the chain verified clean — so the loader now
        // only serves playlists and resources that genuinely need
        // disguise-stripping, and plain public files take the
        // plain path.
        if let decoded = decodeProxyWrapped(absolute) { return decoded.absoluteString }
        guard let proxied = proxiedURL(for: absolute) else { return uri }
        return proxied.absoluteString
    }

    private static func decodeProxyWrapped(_ url: URL) -> URL? {
        guard url.path.contains("/__hls_proxy/") else { return nil }
        var b64 = url.lastPathComponent
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let string = String(data: data, encoding: .utf8),
              string.hasPrefix("http"),
              let decoded = URL(string: string),
              (decoded.scheme == "http" || decoded.scheme == "https") else { return nil }
        return decoded
    }

    /// Rewrites every URI="..." attribute on a tag line (EXT-X-MAP,
    /// EXT-X-KEY, EXT-X-MEDIA, EXT-X-STREAM-INF companions...).
    private static func rewriteTagLine(_ line: String, base: URL) -> String {
        guard line.contains("URI=\""),
              let regex = try? NSRegularExpression(pattern: "URI=\"([^\"]*)\"") else { return line }
        let ns = line as NSString
        let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
        var result = line
        for match in matches.reversed() where match.numberOfRanges > 1 {
            let range = match.range(at: 1)
            let uri = ns.substring(with: range)
            let wrapped = wrap(uri, base: base)
            result = (result as NSString).replacingCharacters(in: range, with: wrapped)
        }
        return result
    }

    // MARK: - Content sniffing

    static func sniffContentType(data: Data, url: URL) -> String {
        if data.count >= 8 {
            let box = data.subdata(in: 4..<8)
            if box == Data("ftyp".utf8) || box == Data("styp".utf8) {
                return "public.mpeg-4"
            }
        }
        if data.first == 0x47 {
            return "public.mpeg-2-transport-stream"
        }
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v", "m4s": return "public.mpeg-4"
        case "m4a": return "public.mpeg-4-audio"
        case "aac": return "public.aac-audio"
        case "ts": return "public.mpeg-2-transport-stream"
        case "mp3": return "public.mp3"
        default: return "public.data"
        }
    }
}
