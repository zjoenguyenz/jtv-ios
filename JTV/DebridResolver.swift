import Foundation

/// Where the Torrent tab's debrid tokens come from: a token typed
/// in Settings (UserDefaults) wins; the build-time baked value
/// (DebridSecrets) is the fallback, so a reinstall keeps working
/// without re-typing — the same arrangement the TV apps use.
enum DebridTokens {
    static let rdKey = "jtv_rd_token"
    static let torboxKey = "jtv_torbox_token"

    static var rd: String { stored(rdKey) ?? DebridSecrets.rdToken }
    static var torbox: String { stored(torboxKey) ?? DebridSecrets.torboxToken }

    static var isConfigured: Bool { !rd.isEmpty || !torbox.isEmpty }

    private static func stored(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }
}

enum DebridError: LocalizedError {
    case noToken
    case http(Int, String)
    case message(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Chưa có token Real-Debrid / TorBox. Nhập token trong Cài đặt (mục Torrent) rồi thử lại."
        case .http(let code, let body):
            return "Dịch vụ debrid trả lỗi \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .message(let text):
            return text
        case .timeout:
            return "Torrent chưa có sẵn trên debrid và tải quá lâu. Thử lại sau ít phút — debrid vẫn đang tải ở phía máy chủ."
        }
    }
}

/// Turns a torrent info-hash (the torrenthub plugin's `jtvhash:`
/// episode ids) into a direct file URL via a debrid service.
///
/// Real-Debrid is primary (flow ported from the TV app's RdApi:
/// addMagnet → pick file → selectFiles → poll → unrestrict);
/// TorBox is the fallback when RD is unconfigured or fails. The
/// file pick prefers the largest VIDEO file, preferring
/// AVPlayer-friendly containers (mp4/m4v/mov) so most titles stay
/// on the native player; anything else is flagged
/// `useCompatEngine` and the resolver screen routes it to the
/// KSPlayer (FFmpeg) surface, which opens MKV/AVI natively.
enum DebridResolver {
    private static let videoExts: Set<String> = ["mkv", "mp4", "avi", "m4v", "mov", "ts", "m2ts", "wmv", "flv", "webm"]
    private static let friendlyExts: Set<String> = ["mp4", "m4v", "mov"]
    /// Server-side downloads of uncached torrents get a long but
    /// bounded budget; past it the user gets a clear message
    /// instead of an endless spinner.
    private static let budget: TimeInterval = 900

    static func resolve(hash: String) async throws -> StreamInfo {
        let clean = hash.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.count >= 32 else { throw DebridError.message("Mã torrent không hợp lệ.") }
        var lastError: Error = DebridError.noToken
        if !DebridTokens.rd.isEmpty {
            do {
                return try await resolveRD(hash: clean, token: DebridTokens.rd)
            } catch {
                lastError = error
            }
        }
        if !DebridTokens.torbox.isEmpty {
            do {
                return try await resolveTorBox(hash: clean, token: DebridTokens.torbox)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func needsCompatEngine(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return !ext.isEmpty && !friendlyExts.contains(ext)
    }

    // MARK: - Real-Debrid

    private static func resolveRD(hash: String, token: String) async throws -> StreamInfo {
        let base = "https://api.real-debrid.com/rest/1.0"
        let magnet = "magnet:?xt=urn:btih:" + hash
        let added = try await rdRequest(base, token, "POST", "/torrents/addMagnet", form: ["magnet": magnet])
        guard let id = added["id"] as? String, !id.isEmpty else {
            throw DebridError.message("Real-Debrid không nhận magnet này.")
        }

        let info = try await rdRequest(base, token, "GET", "/torrents/info/\(id)", form: nil)
        let files = (info["files"] as? [[String: Any]]) ?? []
        guard let pick = pickFile(files.map {
            (id: ($0["id"] as? Int) ?? -1,
             bytes: ($0["bytes"] as? Int) ?? 0,
             path: ($0["path"] as? String) ?? "")
        }) else {
            throw DebridError.message("Torrent không có file nào chọn được.")
        }
        _ = try await rdRequest(base, token, "POST", "/torrents/selectFiles/\(id)", form: ["files": String(pick.id)])

        let deadline = Date().addingTimeInterval(budget)
        var link: String?
        while link == nil {
            let poll = try await rdRequest(base, token, "GET", "/torrents/info/\(id)", form: nil)
            if let status = poll["status"] as? String, status == "magnet_error" || status == "error" || status == "dead" {
                throw DebridError.message("Real-Debrid báo torrent lỗi (trạng thái \(status)).")
            }
            if let links = poll["links"] as? [String], let first = links.first, !first.isEmpty {
                link = first
            } else {
                if Date() > deadline { throw DebridError.timeout }
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        let unrestricted = try await rdRequest(base, token, "POST", "/unrestrict/link", form: ["link": link!])
        guard let download = unrestricted["download"] as? String, !download.isEmpty else {
            throw DebridError.message("Real-Debrid không trả link tải.")
        }
        let filename = (unrestricted["filename"] as? String) ?? pick.path
        return StreamInfo(url: download, headers: [:], useCompatEngine: needsCompatEngine(filename: filename))
    }

    private static func rdRequest(_ base: String, _ token: String, _ method: String, _ path: String, form: [String: String]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(form)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DebridError.http(code, String(data: data, encoding: .utf8)?.prefix(160).description ?? "")
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - TorBox

    private static func resolveTorBox(hash: String, token: String) async throws -> StreamInfo {
        let base = "https://api.torbox.app/v1/api"
        let magnet = "magnet:?xt=urn:btih:" + hash
        let created = try await torboxRequest(base, token, "POST", "/torrents/createtorrent", form: ["magnet": magnet])
        let createdData = (created["data"] as? [String: Any]) ?? [:]
        guard let torrentId = (createdData["torrent_id"] as? Int) ?? (created["torrent_id"] as? Int) else {
            throw DebridError.message("TorBox không nhận magnet này.")
        }

        let deadline = Date().addingTimeInterval(budget)
        var downloadURL: String?
        var pickedName = ""
        while downloadURL == nil {
            let list = try await torboxRequest(base, token, "GET", "/torrents/mylist", form: nil)
            let torrents = (list["data"] as? [[String: Any]]) ?? []
            if let entry = torrents.first(where: { ($0["id"] as? Int) == torrentId }) {
                let finished = (entry["download_finished"] as? Bool) ?? false
                let present = (entry["download_present"] as? Bool) ?? false
                if finished || present {
                    let files = (entry["files"] as? [[String: Any]]) ?? []
                    guard let pick = pickFile(files.map {
                        (id: ($0["id"] as? Int) ?? -1,
                         bytes: ($0["size"] as? Int) ?? 0,
                         path: ($0["short_name"] as? String) ?? ($0["name"] as? String) ?? "")
                    }) else {
                        throw DebridError.message("Torrent không có file nào chọn được.")
                    }
                    pickedName = pick.path
                    downloadURL = try await torboxDownloadURL(base, token, torrentId, pick.id)
                }
            }
            if downloadURL == nil {
                if Date() > deadline { throw DebridError.timeout }
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        return StreamInfo(url: downloadURL!, headers: [:], useCompatEngine: needsCompatEngine(filename: pickedName))
    }

    private static func torboxDownloadURL(_ base: String, _ token: String, _ torrentId: Int, _ fileId: Int) async throws -> String {
        var components = URLComponents(string: base + "/torrents/requestdl")!
        components.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "torrent_id", value: String(torrentId)),
            URLQueryItem(name: "file_id", value: String(fileId)),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else {
            throw DebridError.http(code, String(body.prefix(160)))
        }
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let url = json["data"] as? String, !url.isEmpty {
            return url
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http") { return trimmed }
        throw DebridError.message("TorBox không trả link tải.")
    }

    private static func torboxRequest(_ base: String, _ token: String, _ method: String, _ path: String, form: [String: String]?) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = formBody(form)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw DebridError.http(code, String(data: data, encoding: .utf8)?.prefix(160).description ?? "")
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - Shared

    private static func formBody(_ form: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let parts = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        return Data(parts.joined(separator: "&").utf8)
    }

    /// Picks the file a player should receive: the largest video
    /// file, preferring AVPlayer-friendly containers so most titles
    /// stay on the native player; falls back to the largest file of
    /// any kind when no video extension is recognisable.
    private static func pickFile(_ files: [(id: Int, bytes: Int, path: String)]) -> (id: Int, path: String)? {
        let valid = files.filter { $0.id >= 0 }
        guard !valid.isEmpty else { return nil }
        func ext(_ path: String) -> String { (path as NSString).pathExtension.lowercased() }
        let videos = valid.filter { videoExts.contains(ext($0.path)) }
        if !videos.isEmpty {
            let friendly = videos.filter { friendlyExts.contains(ext($0.path)) }
            let pool = friendly.isEmpty ? videos : friendly
            let best = pool.max(by: { $0.bytes < $1.bytes })!
            return (best.id, best.path)
        }
        let best = valid.max(by: { $0.bytes < $1.bytes })!
        return (best.id, best.path)
    }
}
