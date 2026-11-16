import Foundation

/// Where the Torrent tab's debrid tokens come from: a token typed
/// in Settings (UserDefaults) wins; the build-time baked value
/// (DebridSecrets) is the fallback, so a reinstall keeps working
/// without re-typing — the same arrangement the TV apps use.
enum DebridTokens {
    static let rdKey = "jtv_rd_token"
    static let torboxKey = "jtv_torbox_token"
    static let premiumizeKey = "jtv_pm_token"

    static var rd: String { stored(rdKey) ?? DebridSecrets.rdToken }
    static var torbox: String { stored(torboxKey) ?? DebridSecrets.torboxToken }
    static var premiumize: String { stored(premiumizeKey) ?? DebridSecrets.premiumizeToken }

    static var isConfigured: Bool { !rd.isEmpty || !torbox.isEmpty || !premiumize.isEmpty }

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
    /// Internal signal, never shown: the provider accepted the
    /// torrent and is still downloading it server-side when the
    /// caller's window closed. The orchestrator uses it to move
    /// to the next provider instead of parking on this one.
    case downloading

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "Chưa có token debrid. Nhập token TorBox, Premiumize hoặc Real-Debrid trong Cài đặt (mục Torrent) rồi thử lại."
        case .http(let code, let body):
            return "Dịch vụ debrid trả lỗi \(code)\(body.isEmpty ? "" : ": \(body)")"
        case .message(let text):
            return text
        case .timeout, .downloading:
            return "Torrent chưa có sẵn trên debrid và tải quá lâu. Thử lại sau ít phút — debrid vẫn đang tải ở phía máy chủ."
        }
    }
}

/// Turns a torrent info-hash (the torrenthub plugin's `jtvhash:`
/// episode ids) into a direct file URL via a debrid service.
///
/// Provider preference (owner ruling 2026-11-16): TorBox first,
/// then Premiumize, then Real-Debrid (whose flow is ported from
/// the TV app's RdApi: addMagnet → pick file → selectFiles →
/// poll → unrestrict) — among providers that HAVE the torrent:
/// a provider still downloading server-side only gets a short
/// first-pass window before the next provider is tried, and a
/// cached link anywhere wins over a download everywhere. The
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
        let tb = DebridTokens.torbox, pm = DebridTokens.premiumize, rd = DebridTokens.rd
        guard !tb.isEmpty || !pm.isEmpty || !rd.isEmpty else { throw DebridError.noToken }
        let started = Date()
        let globalDeadline = started.addingTimeInterval(budget)
        var lastError: Error = DebridError.noToken
        var downloading: [(order: Int, run: (Date) async throws -> StreamInfo)] = []

        // Premiumize cache probe: directdl answers with real links
        // in ONE call when the torrent is already on their system.
        var pmCached: StreamInfo?
        if !pm.isEmpty {
            pmCached = try? await premiumizeDirectDL(hash: clean, token: pm)
        }

        // TorBox pass. When Premiumize already has the file, the
        // window is short: a cached TorBox torrent resolves inside
        // it and wins by preference; a still-downloading one yields
        // to the cached Premiumize link instead of parking the user.
        if !tb.isEmpty {
            let window = started.addingTimeInterval(pmCached != nil ? 20 : 45)
            do {
                return try await resolveTorBox(hash: clean, token: tb, deadline: window)
            } catch DebridError.downloading {
                downloading.append((0, { dl in try await resolveTorBox(hash: clean, token: tb, deadline: dl) }))
            } catch {
                lastError = error
            }
        }
        if let pmCached { return pmCached }

        // Premiumize full pass (create + poll) when the probe missed.
        if !pm.isEmpty {
            let window = started.addingTimeInterval(45)
            do {
                return try await resolvePremiumize(hash: clean, token: pm, deadline: window)
            } catch DebridError.downloading {
                downloading.append((1, { dl in try await resolvePremiumize(hash: clean, token: pm, deadline: dl) }))
            } catch {
                lastError = error
            }
        }

        // Real-Debrid pass.
        if !rd.isEmpty {
            let window = started.addingTimeInterval(45)
            do {
                return try await resolveRD(hash: clean, token: rd, deadline: window)
            } catch DebridError.downloading {
                downloading.append((2, { dl in try await resolveRD(hash: clean, token: rd, deadline: dl) }))
            } catch {
                lastError = error
            }
        }

        // Every configured provider is still downloading: settle
        // on the most preferred one for the remaining budget.
        if let first = downloading.sorted(by: { $0.order < $1.order }).first {
            do {
                return try await first.run(globalDeadline)
            } catch DebridError.downloading {
                throw DebridError.timeout
            }
        }
        throw lastError
    }

    static func needsCompatEngine(filename: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        return !ext.isEmpty && !friendlyExts.contains(ext)
    }

    // MARK: - Real-Debrid

    private static func resolveRD(hash: String, token: String, deadline: Date) async throws -> StreamInfo {
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

        var link: String?
        while link == nil {
            let poll = try await rdRequest(base, token, "GET", "/torrents/info/\(id)", form: nil)
            if let status = poll["status"] as? String, status == "magnet_error" || status == "error" || status == "dead" {
                throw DebridError.message("Real-Debrid báo torrent lỗi (trạng thái \(status)).")
            }
            if let links = poll["links"] as? [String], let first = links.first, !first.isEmpty {
                link = first
            } else {
                if Date() > deadline { throw DebridError.downloading }
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

    private static func resolveTorBox(hash: String, token: String, deadline: Date) async throws -> StreamInfo {
        let base = "https://api.torbox.app/v1/api"
        let magnet = "magnet:?xt=urn:btih:" + hash
        let created = try await torboxRequest(base, token, "POST", "/torrents/createtorrent", form: ["magnet": magnet])
        let createdData = (created["data"] as? [String: Any]) ?? [:]
        guard let torrentId = (createdData["torrent_id"] as? Int) ?? (created["torrent_id"] as? Int) else {
            throw DebridError.message("TorBox không nhận magnet này.")
        }

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
                if Date() > deadline { throw DebridError.downloading }
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

    // MARK: - Premiumize

    /// Cache probe: when the torrent is already on Premiumize,
    /// directdl answers with the final file links in one call.
    /// Throws (message) when it is not cached — callers use `try?`.
    private static func premiumizeDirectDL(hash: String, token: String) async throws -> StreamInfo {
        let magnet = "magnet:?xt=urn:btih:" + hash
        let response = try await pmRequest(token, "POST", "/transfer/directdl", form: ["src": magnet], query: nil)
        guard (response["status"] as? String) == "success" else {
            throw DebridError.message("Premiumize chưa có sẵn torrent này.")
        }
        let content = (response["content"] as? [[String: Any]]) ?? []
        let rows: [(id: Int, bytes: Int, path: String)] = content.enumerated().map { pair in
            (id: pair.offset,
             bytes: (pair.element["size"] as? Int) ?? 0,
             path: (pair.element["path"] as? String) ?? "")
        }
        guard let pick = pickFile(rows),
              let link = content[pick.id]["link"] as? String, !link.isEmpty else {
            throw DebridError.message("Premiumize chưa có sẵn torrent này.")
        }
        return StreamInfo(url: link, headers: [:], useCompatEngine: needsCompatEngine(filename: pick.path))
    }

    private static func resolvePremiumize(hash: String, token: String, deadline: Date) async throws -> StreamInfo {
        let magnet = "magnet:?xt=urn:btih:" + hash
        let created = try await pmRequest(token, "POST", "/transfer/create", form: ["src": magnet], query: nil)
        guard (created["status"] as? String) == "success", let transferId = created["id"] as? String, !transferId.isEmpty else {
            throw DebridError.message("Premiumize không nhận magnet này.")
        }
        while true {
            let list = try await pmRequest(token, "GET", "/transfer/list", form: nil, query: nil)
            let transfers = (list["transfers"] as? [[String: Any]]) ?? []
            if let entry = transfers.first(where: { ($0["id"] as? String) == transferId }) {
                let status = (entry["status"] as? String) ?? ""
                if status == "error" {
                    let detail = (entry["message"] as? String) ?? ""
                    throw DebridError.message("Premiumize báo torrent lỗi\(detail.isEmpty ? "" : ": \(detail)")")
                }
                if status == "finished" || status == "seeding" {
                    if let folderId = entry["folder_id"] as? String, !folderId.isEmpty,
                       let picked = try await premiumizeFolderPick(token, folderId) {
                        return picked
                    }
                    // Single-file transfer, or the folder listing
                    // carried no playable file: the content is in
                    // the cloud now, so directdl should answer.
                    if let hit = try? await premiumizeDirectDL(hash: hash, token: token) { return hit }
                    throw DebridError.message("Premiumize đã tải xong nhưng không lấy được link file.")
                }
            }
            if Date() > deadline { throw DebridError.downloading }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private static func premiumizeFolderPick(_ token: String, _ folderId: String) async throws -> StreamInfo? {
        let folder = try await pmRequest(token, "GET", "/folder/list", form: nil, query: ["id": folderId])
        let content = ((folder["content"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "file" }
        let rows: [(id: Int, bytes: Int, path: String)] = content.enumerated().map { pair in
            (id: pair.offset,
             bytes: (pair.element["size"] as? Int) ?? 0,
             path: (pair.element["name"] as? String) ?? "")
        }
        guard let pick = pickFile(rows),
              let link = content[pick.id]["link"] as? String, !link.isEmpty else { return nil }
        return StreamInfo(url: link, headers: [:], useCompatEngine: needsCompatEngine(filename: pick.path))
    }

    private static func pmRequest(_ token: String, _ method: String, _ path: String, form: [String: String]?, query: [String: String]?) async throws -> [String: Any] {
        var components = URLComponents(string: "https://www.premiumize.me/api" + path)!
        if let query {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
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
