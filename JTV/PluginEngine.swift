import Foundation
import JavaScriptCore

enum PluginEngineError: Error, LocalizedError {
    case notLoaded
    case functionMissing(String)
    case jsException(String)
    case badResult(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Plugin chưa được nạp."
        case .functionMissing(let f): return "Plugin thiếu hàm \(f)."
        case .jsException(let m): return "Lỗi JS: \(m)"
        case .badResult(let f): return "Kết quả không hợp lệ từ \(f)."
        }
    }
}

/// Runs one plugin script inside a JSContext. JSContext is not
/// thread-safe, so every call is serialized on a dedicated queue and
/// exposed to Swift as async APIs.
final class PluginEngine {
    let pluginIdHint: String
    private let queue: DispatchQueue
    private var context: JSContext?
    private var lastException: String?

    init(pluginId: String) {
        self.pluginIdHint = pluginId
        self.queue = DispatchQueue(label: "jtv.pluginengine.\(pluginId)")
    }

    // MARK: - Lifecycle

    func load(script: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                let ctx = JSContext()
                ctx?.exceptionHandler = { [weak self] _, exc in
                    self?.lastException = exc?.toString() ?? "unknown"
                }
                ctx?.evaluateScript(script)
                self.context = ctx
                cont.resume()
            }
        }
    }

    var isLoaded: Bool {
        get async {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                queue.async { cont.resume(returning: self.context != nil) }
            }
        }
    }

    func hasFunction(_ name: String) async -> Bool {
        await run { ctx in
            guard let ctx else { return false }
            guard let v = ctx.objectForKeyedSubscript(name) else { return false }
            return !v.isUndefined && !v.isNull
        }
    }

    // MARK: - Raw call helpers

    /// Runs `body` on the engine queue (context may be nil if not loaded).
    private func run<T>(_ body: @escaping (JSContext?) -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            queue.async { cont.resume(returning: body(self.context)) }
        }
    }

    /// Calls a JS function with string arguments; returns its string result.
    private func callString(_ function: String, args: [String]) async throws -> String {
        let result: String? = await run { ctx in
            guard let ctx else { return nil }
            self.lastException = nil
            guard let fn = ctx.objectForKeyedSubscript(function),
                  !fn.isUndefined, !fn.isNull else { return nil }
            let value = fn.call(withArguments: args)
            if let exc = self.lastException { return "\u{1}EXC:\(exc)" }
            return value?.toString() ?? ""
        }
        guard let result else { throw PluginEngineError.notLoaded }
        if result.hasPrefix("\u{1}EXC:") {
            throw PluginEngineError.jsException(String(result.dropFirst(5)))
        }
        return result
    }

    private func decode<T: Decodable>(_ type: T.Type, from json: String, function: String) throws -> T {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else {
            throw PluginEngineError.badResult(function)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw PluginEngineError.badResult("\(function): \(error.localizedDescription)")
        }
    }

    // MARK: - Contract: metadata & discovery

    func manifest() async -> PluginManifest? {
        guard await hasFunction("getManifest") else { return nil }
        guard let json = try? await callString("getManifest", args: []) else { return nil }
        return try? decode(PluginManifest.self, from: json, function: "getManifest")
    }

    func homeSections() async -> [HomeSection] {
        guard await hasFunction("getHomeSections"),
              let json = try? await callString("getHomeSections", args: []) else { return [] }
        return (try? decode([HomeSection].self, from: json, function: "getHomeSections")) ?? []
    }

    func primaryCategories() async -> [NameSlug] {
        guard await hasFunction("getPrimaryCategories"),
              let json = try? await callString("getPrimaryCategories", args: []) else { return [] }
        return (try? decode([NameSlug].self, from: json, function: "getPrimaryCategories")) ?? []
    }

    func filterConfig() async -> FilterConfig {
        guard await hasFunction("getFilterConfig"),
              let json = try? await callString("getFilterConfig", args: []),
              let data = json.data(using: .utf8) else { return FilterConfig() }
        return FilterConfig.decode(from: data)
    }

    // MARK: - Contract: lists & search

    func urlForList(slug: String, filtersJson: String) async -> String? {
        guard await hasFunction("getUrlList") else { return nil }
        let url = try? await callString("getUrlList", args: [slug, filtersJson])
        return (url?.isEmpty == false) ? url : nil
    }

    func parseList(text: String) async -> ListPage {
        guard await hasFunction("parseListResponse"),
              let json = try? await callString("parseListResponse", args: [text]) else {
            return ListPage()
        }
        return (try? decode(ListPage.self, from: json, function: "parseListResponse")) ?? ListPage()
    }

    func urlForSearch(keyword: String, filtersJson: String) async -> String? {
        guard await hasFunction("getUrlSearch") else { return nil }
        let url = try? await callString("getUrlSearch", args: [keyword, filtersJson])
        return (url?.isEmpty == false) ? url : nil
    }

    func parseSearch(text: String) async -> ListPage {
        // Some plugins only implement parseListResponse; fall back to it.
        if await hasFunction("parseSearchResponse"),
           let json = try? await callString("parseSearchResponse", args: [text]),
           let page = try? decode(ListPage.self, from: json, function: "parseSearchResponse") {
            return page
        }
        return await parseList(text: text)
    }

    // MARK: - Contract: detail & streams

    func urlForDetail(slug: String) async -> String? {
        guard await hasFunction("getUrlDetail") else { return nil }
        let url = try? await callString("getUrlDetail", args: [slug])
        return (url?.isEmpty == false) ? url : nil
    }

    func parseMovieDetail(text: String) async -> MovieDetail? {
        guard await hasFunction("parseMovieDetail"),
              let json = try? await callString("parseMovieDetail", args: [text]) else { return nil }
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "null" || trimmed.isEmpty { return nil }
        return try? decode(MovieDetail.self, from: trimmed, function: "parseMovieDetail")
    }

    /// parseDetailResponse on any fetched payload (detail JSON, chapter
    /// JSON, or embed HTML depending on the plugin).
    func parseStream(text: String) async -> StreamInfo {
        guard await hasFunction("parseDetailResponse"),
              let json = try? await callString("parseDetailResponse", args: [text]) else {
            return StreamInfo()
        }
        return (try? decode(StreamInfo.self, from: json, function: "parseDetailResponse")) ?? StreamInfo()
    }

    func parseEmbed(html: String) async -> StreamInfo? {
        guard await hasFunction("parseEmbedResponse"),
              let json = try? await callString("parseEmbedResponse", args: [html]) else { return nil }
        return try? decode(StreamInfo.self, from: json, function: "parseEmbedResponse")
    }

    // MARK: - Contract: filter option lists

    func urlForCategories() async -> String? {
        guard await hasFunction("getUrlCategories") else { return nil }
        let url = try? await callString("getUrlCategories", args: [])
        return (url?.isEmpty == false) ? url : nil
    }

    func parseCategories(text: String) async -> [NameSlug] {
        guard await hasFunction("parseCategoriesResponse"),
              let json = try? await callString("parseCategoriesResponse", args: [text]) else { return [] }
        return (try? decode([NameSlug].self, from: json, function: "parseCategoriesResponse")) ?? []
    }

    func urlForCountries() async -> String? {
        guard await hasFunction("getUrlCountries") else { return nil }
        let url = try? await callString("getUrlCountries", args: [])
        return (url?.isEmpty == false) ? url : nil
    }

    func parseCountries(text: String) async -> [NameValue] {
        guard await hasFunction("parseCountriesResponse"),
              let json = try? await callString("parseCountriesResponse", args: [text]) else { return [] }
        return (try? decode([NameValue].self, from: json, function: "parseCountriesResponse")) ?? []
    }

    func urlForYears() async -> String? {
        guard await hasFunction("getUrlYears") else { return nil }
        let url = try? await callString("getUrlYears", args: [])
        return (url?.isEmpty == false) ? url : nil
    }

    func parseYears(text: String) async -> [NameValue] {
        guard await hasFunction("parseYearsResponse"),
              let json = try? await callString("parseYearsResponse", args: [text]) else { return [] }
        return (try? decode([NameValue].self, from: json, function: "parseYearsResponse")) ?? []
    }
}
