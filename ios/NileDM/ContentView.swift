import SwiftUI

struct ContentView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var toast: Toast
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            BrowserScreen()
                .tabItem { Label("المتصفح", systemImage: "globe") }
                .tag(0)
            DownloadsScreen()
                .tabItem { Label("التحميلات", systemImage: "arrow.down.circle") }
                .badge(downloads.activeCount)
                .tag(1)
            SettingsScreen()
                .tabItem { Label("الإعدادات", systemImage: "gearshape") }
                .tag(2)
        }
        .overlay(alignment: .bottom) {
            if let message = toast.message {
                Text(message)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 11)
                    .background(Capsule().fill(Color.black.opacity(0.82)))
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { if downloads.activeCount > 0 { selection = 1 } }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: toast.message)
    }
}
