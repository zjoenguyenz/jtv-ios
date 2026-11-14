import Foundation
import SwiftUI
import UIKit
import WebKit

// MARK: - Networking

enum Net {
    static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
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
        var lastError: Error = URLError(.unknown)
        var triedWebView = false
        for attempt in 0..<3 {
            do {
                var req = makeRequest(url: url, headers: headers)
                req.timeoutInterval = 20
                let (data, response) = try await session.data(for: req)
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
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
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        throw lastError
    }

    static func fetchData(_ urlString: String, headers: [String: String] = [:]) async throws -> Data {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (data, _) = try await session.data(for: makeRequest(url: url, headers: headers))
        return data
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

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var busy = false

    static func fetchHTML(url: URL) async -> String? {
        await shared.fetch(url: url)
    }

    private func fetch(url: URL) async -> String? {
        while busy {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        busy = true
        defer { busy = false }
        return await load(url: url)
    }

    private func ensureWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = Net.defaultUA
        wv.navigationDelegate = self
        webView = wv
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

    private func load(url: URL) async -> String? {
        let wv = ensureWebView()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.continuation = cont
            self.timeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 40_000_000_000)
                self.finish(nil)
            }
            var req = URLRequest(url: url)
            req.setValue(Net.defaultUA, forHTTPHeaderField: "User-Agent")
            wv.stopLoading()
            wv.load(req)
        }
    }

    private func finish(_ html: String?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume(returning: html)
        continuation = nil
    }

    private func harvestCookies(from webView: WKWebView) async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // The challenge needs a beat to solve and redirect; poll
            // the DOM until it turns into the real page.
            for attempt in 0..<6 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 800_000_000 : 1_200_000_000)
                let raw = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
                guard let html = raw as? String else { continue }
                if Net.isChallengeHTML(html) { continue }
                await self.harvestCookies(from: webView)
                self.finish(html)
                return
            }
            let raw = try? await webView.evaluateJavaScript("document.documentElement.outerHTML")
            self.finish(raw as? String)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }
}

// MARK: - Image cache

final class ImageCacheManager {
    static let shared = ImageCacheManager()

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 256 * 1024 * 1024
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

        lock.lock()
        if let existing = inFlight[k] {
            lock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> {
            defer {
                self.lock.lock(); self.inFlight[k] = nil; self.lock.unlock()
            }
            var req = Net.makeRequest(url: url, headers: headers)
            req.timeoutInterval = 30
            guard let (data, _) = try? await Net.session.data(for: req),
                  let image = UIImage(data: data) else { return nil }
            self.cache.setObject(image, forKey: k as NSString, cost: data.count)
            return image
        }
        inFlight[k] = task
        lock.unlock()
        return await task.value
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
