import SwiftUI

struct ContentView: View {
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var toast: Toast
    @EnvironmentObject var tabs: TabsModel
    private static var selfTestDone = false

    var body: some View {
        TabView(selection: $tabs.screen) {
            BrowserScreen()
                .tabItem { Label(tr("المتصفح", "Browser"), systemImage: "globe") }
                .tag(0)
            DownloadsScreen()
                .tabItem { Label(tr("التحميلات", "Downloads"), systemImage: "arrow.down.circle") }
                .badge(downloads.activeCount)
                .tag(1)
            SettingsScreen()
                .tabItem { Label(tr("الإعدادات", "Settings"), systemImage: "gearshape") }
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
                    .onTapGesture { if downloads.activeCount > 0 { tabs.screen = 1 } }
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

    private func tapVideoButtonWhenFound(tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if tabs.current.visibleMedia.isEmpty && tries > 0 { return tapVideoButtonWhenFound(tries: tries - 1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                tabs.current.webView.evaluateJavaScript("window.__ndmTapFirst && window.__ndmTapFirst()")
            }
        }
    }

    /// Used only by the automated check on GitHub:
    /// `-NDMSelfTest <url>...` starts downloads and opens the list, `-NDMShowDownloads` just opens the list.
    private func runSelfTestIfAsked() {
        guard !Self.selfTestDone else { return }
        Self.selfTestDone = true
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-NDMShowDownloads") { tabs.screen = 1 }
        if let i = args.firstIndex(of: "-NDMScreen"), i + 1 < args.count, let n = Int(args[i + 1]) { tabs.screen = n }
        if let i = args.firstIndex(of: "-NDMOpen"), i + 1 < args.count {
            tabs.current.open(args[i + 1])
            if args.contains("-NDMShowMedia") { showMediaWhenFound(tries: 90) }
            if args.contains("-NDMTapVideo") { tapVideoButtonWhenFound(tries: 90) }
        }
        guard let i = args.firstIndex(of: "-NDMSelfTest") else { return }
        tabs.screen = 1
        for a in args[(i + 1)...] where a.hasPrefix("http") {
            if let url = URL(string: a) { DownloadManager.shared.add(url: url, pageURL: nil, nameHint: nil, headers: [:]) }
        }
    }
}
