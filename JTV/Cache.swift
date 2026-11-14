import Foundation
import SwiftUI
import UIKit

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

    static func fetchText(_ urlString: String, headers: [String: String] = [:]) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }
        // Up to 3 attempts with a short backoff: the VPN tunnel path can
        // drop or garble a first response (-1011), a retry usually lands.
        var lastError: Error = URLError(.unknown)
        for attempt in 0..<3 {
            do {
                var req = makeRequest(url: url, headers: headers)
                req.timeoutInterval = 20
                let (data, response) = try await session.data(for: req)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
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
