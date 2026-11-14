import Foundation
import SwiftUI

struct PluginSource: Codable, Identifiable {
    var url: String
    var pluginIds: [String] = []
    var id: String { url }
}

struct InstalledPlugin: Identifiable {
    var manifest: PluginManifest
    var sourceURL: String
    var id: String { manifest.id }
}

/// Owns plugin sources, the on-disk scripts, sync, the adult gate and
/// the active-plugin selection.
@MainActor
final class PluginManager: ObservableObject {
    static let defaultSourceURL = "https://raw.githubusercontent.com/zjoenguyenz/jtv-source/main/plugins.json"

    static let adultPluginIds: Set<String> = [
        "missav", "123av", "avdbapi", "sextop1", "sextop2", "topxx",
        "javhd", "vlxx", "njav", "sayhentai", "misskon",
    ]

    @Published private(set) var sources: [PluginSource] = []
    @Published private(set) var installed: [InstalledPlugin] = []
    @Published private(set) var isSyncing = false
    @Published var lastSyncError: String?
    /// Bumps whenever a sync actually added or updated a plugin, so
    /// views can refresh content built from the old scripts.
    @Published private(set) var syncGeneration = 0

    @Published var activePluginId: String {
        didSet { UserDefaults.standard.set(activePluginId, forKey: Keys.activePlugin) }
    }

    @Published var adultEnabled: Bool {
        didSet {
            UserDefaults.standard.set(adultEnabled, forKey: Keys.adultEnabled)
            // Turning the gate off while an adult plugin is active must
            // not leave the app sitting on a now-hidden source.
            if !adultEnabled, isAdult(activePluginId) {
                activePluginId = visiblePlugins.first?.id ?? ""
            }
        }
    }

    /// Plugin ids the user disabled in Settings (persisted).
    @Published private(set) var disabledIds: Set<String> = []

    private enum Keys {
        static let sourceURL = "jtv_plugin_source_url"
        static let activePlugin = "jtv_last_active_plugin_id"
        static let adultEnabled = "jtv_is_adult_enabled"
        static let sources = "jtv_sources"
        static let manifests = "jtv_installed_manifests"
        static let manifestSources = "jtv_installed_manifest_sources"
        static let disabled = "jtv_disabled_plugin_ids"
    }

    private var engines: [String: PluginEngine] = [:]
    private let enginesLock = NSLock()

    // MARK: - Storage locations

    static var pluginsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("JTV/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func scriptFileURL(for pluginId: String) -> URL {
        Self.pluginsDirectory.appendingPathComponent("\(pluginId).js")
    }

    // MARK: - Init / persistence

    init() {
        let defaults = UserDefaults.standard
        self.activePluginId = defaults.string(forKey: Keys.activePlugin) ?? ""
        // The 18+ gate is session-only by the owner's rule: adult sources
        // appear only while he has the switch on, so every launch starts
        // with the gate OFF regardless of the previous session.
        self.adultEnabled = false

        if let data = defaults.data(forKey: Keys.sources),
           let saved = try? JSONDecoder().decode([PluginSource].self, from: data), !saved.isEmpty {
            self.sources = saved
        } else if let custom = defaults.string(forKey: Keys.sourceURL), !custom.isEmpty {
            self.sources = [PluginSource(url: custom, pluginIds: [])]
        } else {
            self.sources = [PluginSource(url: Self.defaultSourceURL, pluginIds: [])]
        }

        if let data = defaults.data(forKey: Keys.disabled),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            self.disabledIds = Set(saved)
        }

        if let data = defaults.data(forKey: Keys.manifests),
           let manifests = try? JSONDecoder().decode([PluginManifest].self, from: data) {
            let sourceMap = defaults.dictionary(forKey: Keys.manifestSources) as? [String: String] ?? [:]
            let fallbackSource = sources.first?.url ?? Self.defaultSourceURL
            self.installed = manifests.map {
                InstalledPlugin(manifest: $0, sourceURL: sourceMap[$0.id] ?? fallbackSource)
            }
        }

        seedBundledPlugins()

        // Display truth: the bundled set mirrors the default source's
        // repo, so until a sync succeeds the source row should still
        // show how many plugins it accounts for — not "0 plugin".
        if let idx = sources.firstIndex(where: { $0.url == Self.defaultSourceURL }),
           sources[idx].pluginIds.isEmpty {
            let bundledIds = installed.filter { $0.sourceURL == "bundled" }.map { $0.id }
            if !bundledIds.isEmpty {
                sources[idx].pluginIds = bundledIds
                persist()
            }
        }

        if activePluginId.isEmpty || !installed.contains(where: { $0.id == activePluginId }) {
            activePluginId = visiblePlugins.first?.id ?? installed.first?.id ?? ""
        }
    }

    /// The app ships with the full plugin set inside the bundle (the
    /// owner's source repo is private, so a fresh install cannot fetch
    /// it). Seeds any missing bundled plugin into the plugins directory.
    /// Bundled plugins carry sourceURL "bundled" so remote sync —
    /// success or failure — never removes them.
    private func seedBundledPlugins() {
        guard let jsonURL = Bundle.main.url(forResource: "plugins", withExtension: "json", subdirectory: "Plugins")
            ?? Bundle.main.url(forResource: "plugins", withExtension: "json"),
            let data = try? Data(contentsOf: jsonURL),
            let file = try? JSONDecoder().decode(PluginManifestFile.self, from: data)
        else { return }

        var changed = false
        for entry in file.plugins where !entry.id.isEmpty {
            let dest = scriptFileURL(for: entry.id)
            let hasScript = FileManager.default.fileExists(atPath: dest.path)
            if !hasScript,
               let src = Bundle.main.url(forResource: "\(entry.id)_plugin", withExtension: "js", subdirectory: "Plugins")
                ?? Bundle.main.url(forResource: "\(entry.id)_plugin", withExtension: "js"),
               let script = try? String(contentsOf: src, encoding: .utf8) {
                try? script.write(to: dest, atomically: true, encoding: .utf8)
            }
            if !installed.contains(where: { $0.id == entry.id }) {
                installed.append(InstalledPlugin(manifest: entry, sourceURL: "bundled"))
                changed = true
            }
        }
        if changed { persist() }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(data, forKey: Keys.sources)
        }
        if let data = try? JSONEncoder().encode(installed.map { $0.manifest }) {
            defaults.set(data, forKey: Keys.manifests)
        }
        var sourceMap: [String: String] = [:]
        for plugin in installed { sourceMap[plugin.id] = plugin.sourceURL }
        defaults.set(sourceMap, forKey: Keys.manifestSources)
        defaults.set(Array(disabledIds), forKey: Keys.disabled)
        defaults.set(sources.first?.url ?? Self.defaultSourceURL, forKey: Keys.sourceURL)
    }

    // MARK: - Visibility

    func isAdult(_ pluginId: String) -> Bool {
        if Self.adultPluginIds.contains(pluginId) { return true }
        // Sources added later can flag a plugin as adult in plugins.json.
        return installed.first { $0.id == pluginId }?.manifest.adult == true
    }

    /// Dotted-numeric version compare ("1.0.10" > "1.0.9"); -1/0/1.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    /// Plugins shown in switchers/pickers: installed, adult gate applied,
    /// not user-disabled.
    var visiblePlugins: [InstalledPlugin] {
        installed.filter { plugin in
            if isAdult(plugin.id) && !adultEnabled { return false }
            return !disabledIds.contains(plugin.id)
        }
    }

    var activePlugin: InstalledPlugin? {
        visiblePlugins.first { $0.id == activePluginId } ?? visiblePlugins.first
    }

    /// Plugin lookup ignoring the adult gate / disabled state (favorites
    /// and history need to resolve their own plugin).
    func installedPlugin(id: String) -> InstalledPlugin? {
        installed.first { $0.id == id }
    }

    func setPluginEnabled(_ pluginId: String, enabled: Bool) {
        if enabled { disabledIds.remove(pluginId) } else { disabledIds.insert(pluginId) }
        if !enabled && activePluginId == pluginId {
            activePluginId = visiblePlugins.first?.id ?? ""
        }
        if enabled && activePluginId.isEmpty {
            activePluginId = pluginId
        }
        persist()
    }

    func isPluginEnabled(_ pluginId: String) -> Bool { !disabledIds.contains(pluginId) }

    // MARK: - Engines

    func engine(for pluginId: String) async -> PluginEngine? {
        enginesLock.lock()
        if let cached = engines[pluginId] {
            enginesLock.unlock()
            return cached
        }
        enginesLock.unlock()

        let file = scriptFileURL(for: pluginId)
        guard let script = try? String(contentsOf: file, encoding: .utf8), !script.isEmpty else {
            return nil
        }
        let engine = PluginEngine(pluginId: pluginId)
        await engine.load(script: script)
        enginesLock.lock()
        engines[pluginId] = engine
        enginesLock.unlock()
        return engine
    }

    private func invalidateEngine(for pluginId: String) {
        enginesLock.lock()
        engines[pluginId] = nil
        enginesLock.unlock()
    }

    // MARK: - Sync

    /// Fetches every source's plugins.json, downloads changed scripts and
    /// rebuilds the installed list. Automatic syncs (launch, pull-to-
    /// refresh) pass silent: a failed update CHECK is not an app error —
    /// the installed set keeps working — so it must never surface as
    /// one. Only a manual sync from Settings reports errors.
    func syncAll(silent: Bool = false) async {
        guard !isSyncing else { return }
        isSyncing = true
        if !silent { lastSyncError = nil }
        defer { isSyncing = false }

        var errors: [String] = []
        var newInstalled: [InstalledPlugin] = []
        var newSources: [PluginSource] = []
        var anyChanged = false

        for source in sources {
            do {
                let synced = try await syncSource(urlString: source.url)
                newInstalled.append(contentsOf: synced.plugins)
                newSources.append(PluginSource(url: source.url, pluginIds: synced.plugins.map { $0.id }))
                anyChanged = anyChanged || synced.changed
            } catch {
                if (error as? URLError)?.code == .badServerResponse {
                    // 404/403 from the raw host — for the owner's own
                    // repo this almost always means it is still private.
                    errors.append("Chưa tải được danh sách nguồn — kho nguồn đang để riêng tư hoặc link chưa đúng. Các nguồn đã cài vẫn chạy bình thường.")
                } else {
                    errors.append(error.localizedDescription)
                }
                // Keep previously installed plugins from this source.
                let kept = installed.filter { $0.sourceURL == source.url }
                newInstalled.append(contentsOf: kept)
                newSources.append(source)
            }
        }

        // Bundled plugins are not owned by any remote source; always keep them.
        newInstalled.append(contentsOf: installed.filter { $0.sourceURL == "bundled" })

        // De-duplicate by plugin id (first source wins).
        var seen = Set<String>()
        installed = newInstalled.filter { seen.insert($0.id).inserted }
        sources = newSources
        if activePluginId.isEmpty || !visiblePlugins.contains(where: { $0.id == activePluginId }) {
            activePluginId = visiblePlugins.first?.id ?? ""
        }
        persist()
        if anyChanged { syncGeneration += 1 }
        if !silent && !errors.isEmpty {
            lastSyncError = errors.joined(separator: "\n")
        }
        if !silent && !installed.isEmpty && errors.isEmpty {
            Haptics.success()
        }
    }

    /// Syncs one source. Updates are version-gated and validated BEFORE
    /// they touch disk: a downloaded script replaces the installed one
    /// only when its own manifest parses, its id matches, and its
    /// version is newer (or the plugin is new). A failed or older entry
    /// keeps the working copy — a bad push can never break a source
    /// that works, the same floor the bundled set provides.
    private func syncSource(urlString: String) async throws -> (plugins: [InstalledPlugin], changed: Bool) {
        let text = try await Net.fetchText(urlString)
        guard let data = text.data(using: .utf8) else { throw URLError(.cannotDecodeContentData) }
        let file = try JSONDecoder().decode(PluginManifestFile.self, from: data)

        var result: [InstalledPlugin] = []
        var changed = false
        for entry in file.plugins where !entry.id.isEmpty && !entry.scriptUrl.isEmpty {
            let existing = installed.first { $0.id == entry.id }
            let fileURL = scriptFileURL(for: entry.id)
            let hasScript = FileManager.default.fileExists(atPath: fileURL.path)

            // Already at this version (or newer): keep, no re-download.
            if let existing, hasScript,
               Self.compareVersions(entry.version, existing.manifest.version) <= 0 {
                var manifest = existing.manifest
                if entry.adult { manifest.adult = true }
                if manifest.iconUrl.isEmpty { manifest.iconUrl = entry.iconUrl }
                result.append(InstalledPlugin(manifest: manifest, sourceURL: existing.sourceURL))
                continue
            }

            do {
                let script = try await Net.fetchText(entry.scriptUrl)
                // Validate first: the script must load and identify
                // itself as this plugin before it earns the disk slot.
                let engine = PluginEngine(pluginId: entry.id)
                await engine.load(script: script)
                guard var manifest = await engine.manifest(),
                      manifest.id == entry.id else {
                    if let existing { result.append(existing) }
                    continue
                }
                if existing != nil,
                   Self.compareVersions(manifest.version, existing!.manifest.version) < 0 {
                    result.append(existing!)
                    continue
                }
                try script.write(to: fileURL, atomically: true, encoding: .utf8)
                invalidateEngine(for: entry.id)
                if manifest.name.isEmpty { manifest.name = entry.name }
                if manifest.iconUrl.isEmpty { manifest.iconUrl = entry.iconUrl }
                if entry.adult { manifest.adult = true }
                manifest.scriptUrl = entry.scriptUrl
                // A plugin that arrived via sync keeps the bundled
                // floor: mark it with the source that delivered it.
                result.append(InstalledPlugin(manifest: manifest, sourceURL: urlString))
                changed = true
            } catch {
                // Keep the working copy; one bad entry must not fail
                // the whole source's other updates.
                if let existing { result.append(existing) }
            }
        }
        return (result, changed)
    }

    // MARK: - Source management

    @discardableResult
    func addSource(urlString: String) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
            lastSyncError = "Link nguồn không hợp lệ."
            return false
        }
        guard !sources.contains(where: { $0.url == trimmed }) else {
            lastSyncError = "Nguồn này đã có trong danh sách."
            return false
        }
        sources.append(PluginSource(url: trimmed, pluginIds: []))
        persist()
        await syncAll()
        return lastSyncError == nil
    }

    func removeSource(_ source: PluginSource) {
        let removedIds = installed.filter { $0.sourceURL == source.url }.map { $0.id }
        for pluginId in removedIds {
            try? FileManager.default.removeItem(at: scriptFileURL(for: pluginId))
            invalidateEngine(for: pluginId)
        }
        installed.removeAll { $0.sourceURL == source.url }
        sources.removeAll { $0.url == source.url }
        if sources.isEmpty {
            sources = [PluginSource(url: Self.defaultSourceURL, pluginIds: [])]
        }
        if !visiblePlugins.contains(where: { $0.id == activePluginId }) {
            activePluginId = visiblePlugins.first?.id ?? ""
        }
        persist()
    }
}
