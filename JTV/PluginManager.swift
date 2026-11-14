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

    func isAdult(_ pluginId: String) -> Bool { Self.adultPluginIds.contains(pluginId) }

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
    /// rebuilds the installed list.
    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        defer { isSyncing = false }

        var errors: [String] = []
        var newInstalled: [InstalledPlugin] = []
        var newSources: [PluginSource] = []

        for source in sources {
            do {
                let plugins = try await syncSource(urlString: source.url)
                newInstalled.append(contentsOf: plugins)
                newSources.append(PluginSource(url: source.url, pluginIds: plugins.map { $0.id }))
            } catch {
                errors.append("\(source.url): \(error.localizedDescription)")
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
        if !errors.isEmpty {
            lastSyncError = errors.joined(separator: "\n")
        }
        if !installed.isEmpty && errors.isEmpty {
            Haptics.success()
        }
    }

    private func syncSource(urlString: String) async throws -> [InstalledPlugin] {
        let text = try await Net.fetchText(urlString)
        guard let data = text.data(using: .utf8) else { throw URLError(.cannotDecodeContentData) }
        let file = try JSONDecoder().decode(PluginManifestFile.self, from: data)

        var result: [InstalledPlugin] = []
        for entry in file.plugins where !entry.id.isEmpty && !entry.scriptUrl.isEmpty {
            let script = try await Net.fetchText(entry.scriptUrl)
            let fileURL = scriptFileURL(for: entry.id)
            try script.write(to: fileURL, atomically: true, encoding: .utf8)
            invalidateEngine(for: entry.id)

            // Parse the real manifest from the script itself.
            let engine = PluginEngine(pluginId: entry.id)
            await engine.load(script: script)
            var manifest = await engine.manifest() ?? entry
            if manifest.id.isEmpty { manifest.id = entry.id }
            if manifest.name.isEmpty { manifest.name = entry.name }
            if manifest.iconUrl.isEmpty { manifest.iconUrl = entry.iconUrl }
            manifest.scriptUrl = entry.scriptUrl
            result.append(InstalledPlugin(manifest: manifest, sourceURL: urlString))
        }
        return result
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
