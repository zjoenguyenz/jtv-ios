import SwiftUI
import AVFoundation

@main
struct JTVApp: App {
    @StateObject private var plugins: PluginManager
    @StateObject private var service: MovieService
    @StateObject private var favorites: FavoritesManager
    @StateObject private var history: WatchHistoryManager
    @StateObject private var presenter: PlaybackPresenter

    init() {
        let manager = PluginManager()
        _plugins = StateObject(wrappedValue: manager)
        _service = StateObject(wrappedValue: MovieService(manager: manager))
        _favorites = StateObject(wrappedValue: FavoritesManager())
        _history = StateObject(wrappedValue: WatchHistoryManager())
        _presenter = StateObject(wrappedValue: PlaybackPresenter())

        // Allow background / PiP audio playback for the video player.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(plugins)
                .environmentObject(service)
                .environmentObject(favorites)
                .environmentObject(history)
                .environmentObject(presenter)
                .preferredColorScheme(.dark)
        }
    }
}
