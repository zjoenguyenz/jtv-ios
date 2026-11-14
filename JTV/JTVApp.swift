import SwiftUI
import UIKit
import AVFoundation

/// App-wide orientation lock. The app is portrait-only everywhere
/// except the playback screen, which opens the lock while visible
/// (PlaybackResolverView) so any source can rotate to landscape.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

enum OrientationHelper {
    private static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
    }

    static func setLock(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationLock = mask
        guard let scene = activeScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }

    /// Asks the scene to actually rotate (used when playback
    /// starts: video opens in landscape; leaving the player asks
    /// for portrait back).
    static func requestGeometry(_ mask: UIInterfaceOrientationMask) {
        activeScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
    }
}

@main
struct JTVApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
