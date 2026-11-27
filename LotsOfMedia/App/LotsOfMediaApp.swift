import SwiftUI
import AVFoundation
import BackgroundTasks
import UserNotifications
import Intents

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: DownloadManager.refreshTaskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in DownloadManager.shared.handleBackgroundRefresh(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: DownloadManager.chargingTaskIdentifier, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            Task { @MainActor in DownloadManager.shared.handleChargingTask(task) }
        }
        // Reconnect to the background download session as early as possible so
        // events that completed while we were terminated are delivered.
        MainActor.assumeIsolated {
            DownloadManager.shared.start()
            // Last queue and position, paused; nothing plays until the user taps play.
            AudioPlayer.shared.restoreSession()
        }
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Siri: "Play <name> in LotsOfMedia".
    func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
        intent is INPlayMediaIntent ? PlayMediaIntentHandler() : nil
    }

    /// Show "Recording finished" even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == DownloadManager.sessionIdentifier else { completionHandler(); return }
        MainActor.assumeIsolated {
            DownloadManager.shared.backgroundCompletionHandler = completionHandler
            DownloadManager.shared.start()
        }
    }
}

@main
struct LotsOfMediaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-designReview") { DesignReviewView() } else { RootView() }
                #else
                RootView()
                #endif
            }
                .environment(app)
                .environment(DownloadManager.shared)
                .environment(AudioPlayer.shared)
                .environment(NetworkMonitor.shared)
                .environment(LiveTVStore.shared)
                .preferredColorScheme(.dark)
                .modifier(ThemeTint())
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-designReview") { return }
                    #endif
                    await app.bootstrap()
                }
        }
        .commands { AppCommands(app: app) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background:
                DownloadManager.shared.prepareForBackground()
                AudioPlayer.shared.saveSession(wait: true)
                if phase == .background { DownloadManager.shared.scheduleBackgroundRefresh() }
            case .active:
                DownloadManager.shared.didBecomeActive()
                app.refreshContentIfStale()
                if let api = app.api {
                    // A failed DVR check retries here; otherwise just refresh recordings.
                    if LiveTVStore.shared.dvr == nil {
                        Task { await LiveTVStore.shared.refresh(api: api) }
                    } else {
                        Task { await LiveTVStore.shared.refreshRecordings(api: api) }
                    }
                }
                if app.status != .connected && app.status != .connecting { Task { await app.connect() } }
            default: break
            }
        }
    }
}
