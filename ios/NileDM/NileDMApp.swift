import AVFoundation
import SwiftUI
import UIKit

@main
struct NileDMApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var tabs = TabsModel()
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var toast = Toast.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tabs)
                .environmentObject(downloads)
                .environmentObject(toast)
                .environment(\.layoutDirection, .rightToLeft)
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
