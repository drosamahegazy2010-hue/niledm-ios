import SwiftUI

struct ContentView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var toast: Toast
    @EnvironmentObject var tabs: TabsModel
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
        .onAppear(perform: runSelfTestIfAsked)
    }

    private func showMediaWhenFound(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if tabs.current.visibleMedia.isEmpty && tries > 0 { return showMediaWhenFound(tries: tries - 1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { // let the stream qualities load
                NotificationCenter.default.post(name: .init("NDMShowMedia"), object: nil)
            }
        }
    }

    /// Used only by the automated check on GitHub:
    /// `-NDMSelfTest <url>...` starts downloads and opens the list, `-NDMShowDownloads` just opens the list.
    private func runSelfTestIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-NDMShowDownloads") { selection = 1 }
        if let i = args.firstIndex(of: "-NDMOpen"), i + 1 < args.count {
            tabs.current.open(args[i + 1])
            if args.contains("-NDMShowMedia") { showMediaWhenFound(tries: 90) }
        }
        guard let i = args.firstIndex(of: "-NDMSelfTest") else { return }
        selection = 1
        for a in args[(i + 1)...] where a.hasPrefix("http") {
            if let url = URL(string: a) { DownloadManager.shared.add(url: url, pageURL: nil, nameHint: nil, headers: [:]) }
        }
    }
}
