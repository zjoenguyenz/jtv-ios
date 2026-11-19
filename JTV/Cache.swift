import Foundation
import SwiftUI
import UIKit
import WebKit
import CryptoKit

// MARK: - Networking

enum Net {
    static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024)
        config.httpMaximumConnectionsPerHost = 12
        return URLSession(configuration: config)
    }()

    static func makeRequest(url: URL, headers: [String: String] = [:], referer: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(defaultUA, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    /// Cloudflare's JS challenge ("Just a moment…") is served with a
    /// 403/503 (rarely a 200 interstitial). Ordinary Cloudflare pages
    /// also carry challenge-platform scripts, so the body marker alone
    /// is not enough — status or the interstitial title must agree.
    static func isCloudflareChallenge(_ text: String, status: Int) -> Bool {
        let t = text.lowercased()
        if t.contains("<title>just a moment") { return true }
        if status == 403 || status == 503 {
            return t.contains("just a moment")
                || t.contains("challenge-platform")
                || t.contains("challenges.cloudflare.com")
        }
        return false
    }

    /// Marker check for rendered DOM coming back from the WebView
    /// fetcher (no HTTP status available there).
    static func isChallengeHTML(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("<title>just a moment") || t.contains("challenges.cloudflare.com")
    }

    static func fetchText(_ urlString: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        // Up to 3 attempts with a short backoff: the VPN tunnel path can
        // drop or garble a first response (-1011), a retry usually lands.
        // v1.22: a hard 4xx (except 429) is NOT retried — the old
        // policy burned ~61 s on failures that could never succeed —
        // and the per-attempt timeout drops to 12 s.
        var lastError: Error = URLError(.unknown)
        var triedWebView = false
        for attempt in 0..<3 {
            var attemptStatus = 0
            do {
                var req = makeRequest(url: url, headers: headers)
                req.timeoutInterval = 12
                let (data, response) = try await session.data(for: req)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                attemptStatus = status
                if isCloudflareChallenge(text, status: status) {
                    // Only a real browser passes this wall. Retrying
                    // URLSession just burns time (the user watched a
                    // 4-minute spinner on SayHentai) — go straight to
                    // the WebView fetcher, once.
                    if !triedWebView {
                        triedWebView = true
                        if let html = await WebFetcher.fetchHTML(url: url),
                           !html.isEmpty, !isChallengeHTML(html) {
                            return html
                        }
                    }
                    throw URLError(.badServerResponse)
                }
                if !(200...299).contains(status) {
                    throw URLError(.badServerResponse)
                }
                return text
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if (400..<500).contains(attemptStatus), attemptStatus != 429 { throw lastError }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    /// POST variant for plugin hop configs that carry a postBody
    /// (e.g. vlxx's /ajax.php player call). Same retry policy.
    static func fetchTextPOST(_ urlString: String, body: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            var attemptStatus = 0
            do {
                var req = makeRequest(url: url, headers: headers)
                req.httpMethod = "POST"
                req.timeoutInterval = 12
                if req.value(forHTTPHeaderField: "Content-Type") == nil {
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                }
                req.httpBody = body.data(using: .utf8)
                let (data, response) = try await session.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                attemptStatus = status
                if !(200...299).contains(status) {
                    throw URLError(.badServerResponse)
                }
                return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if (400..<500).contains(attemptStatus), attemptStatus != 429 { throw lastError }
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    static func fetchData(_ urlString: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        // v1.22: same retry policy as fetchText (was: zero retries).
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            do {
                return try await session.data(for: makeRequest(url: url, headers: headers)).0
            } catch {
                if (error as? URLError)?.code == .cancelled { throw error }
                lastError = error
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }
}

// MARK: - WebView fetcher (Cloudflare-challenge fallback)

/// Some sources (SayHentai) sit behind Cloudflare's JavaScript
/// challenge: plain URLSession requests receive a "Just a moment…"
/// page or stall, while a real WebKit view passes the check. This
/// fetcher loads the page in an off-screen WKWebView, lets the
/// challenge solve itself, returns the rendered HTML, and copies the
/// clearance cookies into the shared cookie jar so Net.session can
/// fetch follow-up pages and chapter images directly (the clearance
/// is bound to this device's IP + user agent, both unchanged).
@MainActor
final class WebFetcher: NSObject, WKNavigationDelegate {
    static let shared = WebFetcher()

    /// One browser lane. v1.22: TWO lanes — Cloudflare-walled
    /// fetches (sayhentai list/detail/chapter) used to queue
    /// behind each other through a single webview, so a chapter
    /// open behind a list fetch could wait 10–40 s. Both lanes
    /// share the default website data store, so one lane's
    /// clearance serves the other (and Net.session, via the
    /// harvested cookies).
    private final class Lane {
        var webView: WKWebView?
        var continuation: CheckedContinuation<String?, Never>?
        var timeoutTask: Task<Void, Never>?
        var busy = false
    }

    private var lanes: [Lane] = [Lane(), Lane()]

    static func fetchHTML(url: URL) async -> String? {
        await shared.fetch(url: url)
    }

    private func fetch(url: URL) async -> String? {
        while true {
            if let lane = lanes.first(where: { !$0.busy }) {
                lane.busy = true
                let html = await load(url: url, lane: lane)
                lane.busy = false
                return html
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private func ensureWebView(lane: Lane) -> WKWebView {
        if let webView = lane.webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = Net.defaultUA
        wv.navigationDelegate = self
        lane.webView = wv
        // Attach invisibly to the key window: WebKit can throttle JS
        // timers in fully detached views, and the challenge is JS.
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            wv.isHidden = true
            window.addSubview(wv)
        }
        return wv
    }

    private func lane(for webView: WKWebView) -> Lane? {
        lanes.first(where: { $0.webView === webView })
    }

    private func load(url: URL, lane: Lane) async -> String? {
        let wv = ensureWebView(lane: lane)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            lane.continuation = cont
            lane.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                self.finish(lane: lane, nil)
            }
            var req = URLRequest(url: url)
            req.setValue(Net.defaultUA, forHTTPHeaderField: "User-Agent")
            wv.stopLoading()
            wv.load(req)
        }
    }

    private func finish(lane: Lane, _ html: String?) {
        lane.timeoutTask?.cancel()
        lane.timeoutTask = nil
        lane.continuation?.resume(returning: html)
        lane.continuation = nil
    }

    private func harvestCookies(from webView: WKWebView) async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let lane = lane(for: webView) else { return }
        Task { @MainActor in
            // The challenge needs a beat to solve and redirect; poll
            // the DOM until it turns into the real page. A
            // cf_clearance cookie means the wall is already passed
            // even if this frame still shows the challenge shell —
            // one short extra beat, then take the DOM as-is.
            for attempt in 0..<6 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 800_000_000 : 1_200_000_000)
                let raw = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
                guard let html = raw as? String else { continue }
                if Net.isChallengeHTML(html) {
                    let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                    if cookies.contains(where: { $0.name == "cf_clearance" }) {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        let settled = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
                        if let settledHTML = settled as? String, !Net.isChallengeHTML(settledHTML) {
                            await self.harvestCookies(from: webView)
                            self.finish(lane: lane, settledHTML)
                            return
                        }
                    }
                    continue
                }
                await self.harvestCookies(from: webView)
                self.finish(lane: lane, html)
                return
            }
            let raw = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
            self.finish(lane: lane, raw as? String)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let lane = lane(for: webView) { finish(lane: lane, nil) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if let lane = lane(for: webView) { finish(lane: lane, nil) }
    }
}

// MARK: - Image cache

final class ImageCacheManager: @unchecked Sendable {
    static let shared = ImageCacheManager()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()
    /// v1.22 disk tier (~300 MB, LRU by modification date): every
    /// cold launch used to re-download every poster — the memory
    /// cache alone could not survive a relaunch.
    private let diskDir: URL
    private let diskCap = 300 * 1024 * 1024

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 256 * 1024 * 1024
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskDir = caches.appendingPathComponent("jtv-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        let dir = diskDir, cap = diskCap
        Task.detached { Self.pruneDisk(dir: dir, cap: cap) }
    }

    private func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDir.appendingPathComponent(digest)
    }

    private static func pruneDisk(dir: URL, cap: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var total = 0
        var sized: [(url: URL, size: Int, date: Date)] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            total += size
            sized.append((entry, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > cap else { return }
        for entry in sized.sorted(by: { $0.date < $1.date }) {
            if total <= cap { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// Real memory cost of a decoded bitmap. The old accounting
    /// used the COMPRESSED byte count, so the 256 MB cap was
    /// fictitious — decoded posters run 5–15× their file size.
    private func decodedCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }

    /// Caps pathological decodes (4K backdrops) at a 2048 px long
    /// edge; normal posters and manga pages pass through untouched.
    private func capped(_ image: UIImage) -> UIImage {
        let pixelW = image.size.width * image.scale
        let pixelH = image.size.height * image.scale
        let longest = max(pixelW, pixelH)
        guard longest > 2048 else { return image }
        let ratio = 2048 / longest
        let target = CGSize(width: pixelW * ratio, height: pixelH * ratio)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    private func key(for url: String, headers: [String: String]) -> String {
        if headers.isEmpty { return url }
        let suffix = headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        return url + "|" + suffix
    }

    func cachedImage(for urlString: String, headers: [String: String] = [:]) -> UIImage? {
        cache.object(forKey: key(for: urlString, headers: headers) as NSString)
    }

    func loadImage(urlString: String, headers: [String: String] = [:]) async -> UIImage? {
        let k = key(for: urlString, headers: headers)
        if let hit = cache.object(forKey: k as NSString) { return hit }
        guard let url = URL(string: urlString) else { return nil }

        // Swift 6: NSLock.lock()/unlock() are unavailable in
        // async contexts; scoped withLock is the sanctioned
        // form. The check-and-set MUST stay inside ONE critical
        // section — the pre-migration code held the lock across
        // the check, the Task creation and the registration,
        // and splitting that into two sections (an earlier
        // conversion did) loses the dedupe guarantee: two
        // concurrent calls could both miss the check and both
        // fetch, and a finishing task's cleanup could clear a
        // successor's registration. So the task is created AND
        // registered inside a single withLock section that
        // returns it; the section itself never awaits.
        let task: Task<UIImage?, Never> = lock.withLock {
            if let existing = inFlight[k] { return existing }
            let created = Task<UIImage?, Never> {
                defer {
                    self.lock.withLock { self.inFlight[k] = nil }
                }
                // Disk tier first: decode + promote to memory.
                let disk = self.diskURL(for: k)
                if let data = try? Data(contentsOf: disk), let image = UIImage(data: data) {
                    let cappedImage = self.capped(image)
                    self.cache.setObject(cappedImage, forKey: k as NSString, cost: self.decodedCost(cappedImage))
                    return cappedImage
                }
                var req = Net.makeRequest(url: url, headers: headers)
                req.timeoutInterval = 30
                guard let (data, _) = try? await Net.session.data(for: req),
                      let image = UIImage(data: data) else { return nil }
                try? data.write(to: disk, options: .atomic)
                let cappedImage = self.capped(image)
                self.cache.setObject(cappedImage, forKey: k as NSString, cost: self.decodedCost(cappedImage))
                return cappedImage
            }
            inFlight[k] = created
            return created
        }
        return await task.value
    }

    /// Warms memory/disk for images about to be scrolled into
    /// (rails after a section lands, the manga reader's next
    /// pages). Deduped against the cache and in-flight loads.
    func prefetch(urlStrings: [String], headers: [String: String] = [:]) {
        for urlString in urlStrings.prefix(60) {
            if cachedImage(for: urlString, headers: headers) != nil { continue }
            Task { _ = await self.loadImage(urlString: urlString, headers: headers) }
        }
    }

    func clear() { cache.removeAllObjects() }
}

/// Async image view backed by ImageCacheManager (supports custom headers,
/// e.g. the Referer manga CDNs require).
struct CachedAsyncImage: View {
    let urlString: String
    var headers: [String: String] = [:]
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.white.opacity(0.25))
                    }
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .overlay { ProgressView().tint(.white.opacity(0.5)) }
            }
        }
        .task(id: urlString) {
            failed = false
            if let cached = ImageCacheManager.shared.cachedImage(for: urlString, headers: headers) {
                image = cached
                return
            }
            let loaded = await ImageCacheManager.shared.loadImage(urlString: urlString, headers: headers)
            if let loaded { image = loaded } else { failed = true }
        }
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func select() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}
