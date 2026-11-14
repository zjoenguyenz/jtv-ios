import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var plugins: PluginManager

    @State private var newSourceURL = ""
    @State private var showAdultConfirm = false
    @State private var addError: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear.jtvBackground()
                List {
                    sourcesSection
                    activePluginSection
                    pluginTogglesSection
                    contentSection
                    aboutSection
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Cài đặt")
            .navigationBarTitleDisplayMode(.large)
            .alert("Bật nội dung 18+?", isPresented: $showAdultConfirm) {
                Button("Huỷ", role: .cancel) {}
                Button("Bật") { plugins.adultEnabled = true }
            } message: {
                Text("Các nguồn plugin 18+ sẽ hiện trong app. Bạn có thể tắt lại bất cứ lúc nào.")
            }
        }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        Section {
            ForEach(plugins.sources) { source in
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.url)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text("\(source.pluginIds.count) plugin")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textFaint)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        plugins.removeSource(source)
                    } label: {
                        Label("Xoá", systemImage: "trash")
                    }
                }
            }

            HStack {
                TextField("https://…/plugins.json", text: $newSourceURL)
                    .font(.system(size: 13, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Thêm") {
                    Task {
                        let ok = await plugins.addSource(urlString: newSourceURL)
                        if ok {
                            newSourceURL = ""
                            addError = nil
                        } else {
                            addError = plugins.lastSyncError
                        }
                    }
                }
                .fontWeight(.bold)
                .disabled(newSourceURL.trimmingCharacters(in: .whitespaces).isEmpty || plugins.isSyncing)
            }

            Button {
                Task { await plugins.syncAll() }
            } label: {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Đồng bộ lại tất cả nguồn")
                    if plugins.isSyncing {
                        Spacer()
                        ProgressView().tint(Theme.accent)
                    }
                }
            }
            .disabled(plugins.isSyncing)

            if let addError {
                Text(addError)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.red)
            } else if let error = plugins.lastSyncError {
                Text(error)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.amber)
            }
        } header: {
            Text("Nguồn plugin")
        } footer: {
            Text("Xoá một nguồn sẽ gỡ luôn các plugin thuộc nguồn đó. Nguồn mặc định là kho JTV riêng — không phụ thuộc tác giả gốc.")
        }
        .listRowBackground(Theme.glassFill)
    }

    // MARK: - Plugins

    private var activePluginSection: some View {
        Section {
            if plugins.visiblePlugins.isEmpty {
                Text("Chưa có plugin nào. Hãy đồng bộ nguồn trước.")
                    .foregroundStyle(Theme.textDim)
            }
            ForEach(plugins.visiblePlugins) { plugin in
                // The whole row is the tap target: tapping anywhere in
                // the cell selects the source, not just the name text.
                HStack(spacing: 11) {
                    CachedAsyncImage(urlString: plugin.manifest.iconUrl)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(plugin.manifest.name)
                                .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                            if plugins.isAdult(plugin.id) {
                                Text("18+")
                                    .font(.system(size: 9, weight: .black, design: .rounded))
                                    .foregroundStyle(Theme.amber)
                            }
                        }
                        Text(plugin.manifest.type + (plugin.manifest.version.isEmpty ? "" : " • v\(plugin.manifest.version)"))
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textFaint)
                    }
                    Spacer()
                    if plugins.activePluginId == plugin.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    plugins.activePluginId = plugin.id
                    Haptics.select()
                }
            }
        } header: {
            Text("Plugin đang dùng")
        }
        .listRowBackground(Theme.glassFill)
    }

    private var pluginTogglesSection: some View {
        Section {
            ForEach(plugins.installed.filter { plugin in
                !plugins.isAdult(plugin.id) || plugins.adultEnabled
            }) { plugin in
                Toggle(isOn: Binding(
                    get: { plugins.isPluginEnabled(plugin.id) },
                    set: { plugins.setPluginEnabled(plugin.id, enabled: $0) }
                )) {
                    HStack(spacing: 11) {
                        CachedAsyncImage(urlString: plugin.manifest.iconUrl)
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(plugin.manifest.name)
                            .font(.system(size: 14, design: .rounded))
                            .foregroundStyle(.white)
                        if plugins.isAdult(plugin.id) {
                            Text("18+")
                                .font(.system(size: 9, weight: .black, design: .rounded))
                                .foregroundStyle(Theme.amber)
                        }
                    }
                }
                .tint(Theme.accent)
            }
        } header: {
            Text("Bật / tắt plugin")
        }
        .listRowBackground(Theme.glassFill)
    }

    // MARK: - Content & about

    private var contentSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { plugins.adultEnabled },
                set: { newValue in
                    if newValue {
                        showAdultConfirm = true
                    } else {
                        plugins.adultEnabled = false
                    }
                }
            )) {
                Label("Nội dung 18+", systemImage: "18.circle")
                    .foregroundStyle(.white)
            }
            .tint(Theme.amber)

            Button(role: .destructive) {
                ImageCacheManager.shared.clear()
            } label: {
                Label("Xoá bộ nhớ đệm ảnh", systemImage: "trash")
            }
        } header: {
            Text("Nội dung")
        } footer: {
            Text("Khi tắt, mọi plugin 18+ bị ẩn khỏi app.")
        }
        .listRowBackground(Theme.glassFill)
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Ứng dụng")
                Spacer()
                Text("JTV")
                    .foregroundStyle(Theme.textDim)
            }
            HStack {
                Text("Phiên bản")
                Spacer()
                Text("\(appVersion) (\(appBuild))")
                    .foregroundStyle(Theme.textDim)
            }
            HStack {
                Text("Số plugin đã cài")
                Spacer()
                Text("\(plugins.installed.count)")
                    .foregroundStyle(Theme.textDim)
            }
            HStack {
                Text("Giao diện")
                Spacer()
                Text("Xanh tối • Kính mờ")
                    .foregroundStyle(Theme.textDim)
            }
        } header: {
            Text("Giới thiệu")
        }
        .listRowBackground(Theme.glassFill)
    }
}
