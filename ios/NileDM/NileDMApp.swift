import AVFoundation
import SwiftUI
import UIKit

@main
struct NileDMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var tabs = TabsModel()
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var toast = Toast.shared
    @AppStorage(L10n.key) private var lang = "ar"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .id(lang) // rebuild every screen in the new language
                .onChange(of: lang) { L10n.apply($0) }
                .environmentObject(tabs)
                .environmentObject(downloads)
                .environmentObject(toast)
                .environment(\.layoutDirection, lang == "en" ? .leftToRight : .rightToLeft)
                .environment(\.locale, Locale(identifier: lang == "en" ? "en" : "ar"))
                .tint(Color("AccentColor"))
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = DownloadManager.shared // recreate background sessions right away so iOS can deliver events
        if !ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-NDM") }) {
            Notifier.requestAuthorization() // (skipped only in the automated simulator check)
        }
        Provision.scheduleReminder()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        return true
    }

    /// iOS woke us up because background downloads finished.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        DownloadManager.shared.setBackgroundHandler(identifier, completionHandler)
    }
}
