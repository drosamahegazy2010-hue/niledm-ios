import Combine
import UIKit
import WebKit

/// Weak proxy so WKUserContentController doesn't keep the tab alive forever.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

/// One browser tab: owns its WKWebView, follows navigation, catches downloads and media.
final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    @Published var urlString = ""
    @Published var title = ""
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var media: [MediaItem] = []

    var onOpenInNewTab: ((URL) -> Void)?
    static var userAgent: String?
    private var observers: [NSKeyValueObservation] = []
    private var blobDownloads: [WKDownload: URL] = [:]

    static let homeURL = URL(string: "https://www.google.com")!

    init(url: URL?) {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = true
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        config.websiteDataStore = .default()
        let proxy = WeakScriptHandler()
        let ucc = WKUserContentController()
        ucc.addUserScript(WKUserScript(source: Sniffer.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.add(proxy, name: Sniffer.handlerName)
        config.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        proxy.target = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observers = [
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in self?.progress = wv.estimatedProgress },
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in self?.title = wv.title ?? "" },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in self?.urlString = wv.url?.absoluteString ?? "" },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in self?.isLoading = wv.isLoading },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in self?.canGoBack = wv.canGoBack },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in self?.canGoForward = wv.canGoForward },
        ]
        webView.load(URLRequest(url: url ?? Self.homeURL))
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Sniffer.handlerName)
    }

    // MARK: Navigation

    /// Address bar input: a URL, or words to search on Google.
    func open(_ input: String) {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var url: URL?
        if text.contains("://"), let u = URL(string: text) {
            url = u
        } else if text.contains("."), !text.contains(" "), let u = URL(string: "https://" + text) {
            url = u
        }
        if url == nil {
            var c = URLComponents(string: "https://www.google.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: text)]
            url = c.url
        }
        if let url { webView.load(URLRequest(url: url)) }
    }

    func reloadOrStop() {
        if webView.isLoading { webView.stopLoading() } else { webView.reload() }
    }

    var displayHost: String {
        guard let u = URL(string: urlString), let h = u.host else { return urlString }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    var pageTitleForFiles: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? displayHost : t
    }

    // MARK: Downloads

    /// Headers that let the server treat our download like the browser's own request.
    func headers(for url: URL, completion: @escaping ([String: String]) -> Void) {
        let referer = webView.url?.absoluteString
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            var h: [String: String] = [:]
            if let ua = BrowserTab.userAgent { h["User-Agent"] = ua }
            if let referer, referer != url.absoluteString { h["Referer"] = referer }
            let cookie = Cookies.header(cookies, for: url)
            if !cookie.isEmpty { h["Cookie"] = cookie }
            completion(h)
        }
    }

    func headers(for url: URL) async -> [String: String] {
        await withCheckedContinuation { cont in
            DispatchQueue.main.async { self.headers(for: url) { cont.resume(returning: $0) } }
        }
    }

    func download(url: URL, nameHint: String? = nil) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            Toast.shared.show("الرابط ده مينفعش يتحمل")
            return
        }
        let page = webView.url
        headers(for: url) { h in
            DispatchQueue.main.async {
                DownloadManager.shared.add(url: url, pageURL: page, nameHint: nameHint, headers: h)
            }
        }
    }

    /// `variant` = a quality the user tapped; otherwise the default quality preference is used.
    func download(media m: MediaItem, quality: String, variant: HLSVariant? = nil) {
        let page = webView.url
        let base = FileNames.sanitize(pageTitleForFiles)
        let bitrate = variant.map { $0.bandwidth } ?? Playlist.bitrate(for: quality, in: m.variants)
        headers(for: m.url) { h in
            DispatchQueue.main.async {
                switch m.kind {
                case .hls:
                    DownloadManager.shared.addHLS(url: m.url, pageURL: page, title: base,
                                                  bitrate: bitrate, headers: h)
                case .video, .audio:
                    let ext = m.url.pathExtension.isEmpty ? (m.kind == .audio ? "m4a" : "mp4") : m.url.pathExtension
                    DownloadManager.shared.addFile(url: m.url, pageURL: page, nameHint: base + "." + ext, headers: h)
                case .dash:
                    Toast.shared.show("النوع ده (DASH) مش مدعوم للأسف")
                }
            }
        }
    }

    // MARK: Media detection

    fileprivate func found(urlString: String, tag: String, pageTitle: String) {
        guard let url = URL(string: urlString) else { return }
        if media.contains(where: { $0.url == url }) { return }
        let ext = url.pathExtension.lowercased()
        let kind: MediaItem.Kind
        switch ext {
        case "m3u8": kind = .hls
        case "mpd": kind = .dash
        case "mp3", "m4a": kind = .audio
        default: kind = tag == "audio" ? .audio : .video
        }
        let name = pageTitle.isEmpty ? pageTitleForFiles : pageTitle
        var item = MediaItem(url: url, kind: kind, pageURL: webView.url, title: name)
        if kind == .hls, media.contains(where: { $0.isMaster }) { item.hidden = true }
        media.insert(item, at: 0)
        if media.count > 30 { media.removeLast() }
        Task { await self.inspect(item) }
    }

    /// Learns qualities of m3u8 streams and sizes of direct files.
    private func inspect(_ item: MediaItem) async {
        let h = await headers(for: item.url)
        if item.kind == .hls {
            guard let text = try? await Playlist.fetch(item.url, headers: h) else { return }
            await MainActor.run {
                guard let i = self.media.firstIndex(where: { $0.url == item.url }) else { return }
                if Playlist.isDRM(text) || (!Playlist.isMaster(text) && Playlist.isLive(text)) {
                    self.media[i].hidden = true
                    return
                }
                if Playlist.isMaster(text) {
                    self.media[i].isMaster = true
                    self.media[i].hidden = false
                    self.media[i].variants = Playlist.variants(text)
                    for j in self.media.indices where j != i && self.media[j].kind == .hls && !self.media[j].isMaster {
                        self.media[j].hidden = true
                    }
                }
            }
        } else if item.kind == .video || item.kind == .audio {
            let size = await Playlist.size(of: item.url, headers: h)
            await MainActor.run {
                if let i = self.media.firstIndex(where: { $0.url == item.url }) {
                    self.media[i].size = size
                    if size >= 0 && size < 200_000 { self.media[i].hidden = true } // tiny UI sounds / previews
                }
            }
        }
    }

    var visibleMedia: [MediaItem] { media.filter { !$0.hidden } }
}

// MARK: - Script messages

extension BrowserTab: WKScriptMessageHandler {
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Sniffer.handlerName, let body = message.body as? [String: Any],
              let url = body["url"] as? String else { return }
        let tag = body["tag"] as? String ?? ""
        let title = body["title"] as? String ?? ""
        NSLog("NileDM: page reported media %@ (%@)", url, tag)
        found(urlString: url, tag: tag, pageTitle: title)
    }
}

// MARK: - Navigation delegate

extension BrowserTab: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload, let url = navigationAction.request.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
                download(url: url)
            } else {
                decisionHandler(.download) // blob: / data: — handled by WebKit, then filed in Downloads
            }
            return
        }
        // non-web links (tel:, mailto:, app links)
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(scheme) {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        var attachment = false
        if let http = response as? HTTPURLResponse,
           let cd = http.value(forHTTPHeaderField: "Content-Disposition")?.lowercased(),
           cd.contains("attachment") {
            attachment = true
        }
        if attachment || !navigationResponse.canShowMIMEType, let url = response.url {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                decisionHandler(.cancel)
                download(url: url, nameHint: response.suggestedFilename)
            } else {
                decisionHandler(.download)
            }
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        // a new page: forget what the old one played (keep anything caught in the last 2 s)
        media.removeAll { Date().timeIntervalSince($0.found) > 2 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("NileDM: page loaded %@", webView.url?.absoluteString ?? "-")
        if BrowserTab.userAgent == nil {
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                if let ua = result as? String { BrowserTab.userAgent = ua }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        NSLog("NileDM: page failed %@ %ld", ns.domain, ns.code)
        if ns.code == NSURLErrorCancelled || ns.code == 102 { return } // 102 = frame load interrupted (download)
        Toast.shared.show("مش قادر أفتح الصفحة: \(ns.localizedDescription)")
    }

    // blob:/data: downloads that only WebKit can perform
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

extension BrowserTab: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dest = Paths.unique(FileNames.sanitize(suggestedFilename), in: Paths.downloads)
        blobDownloads[download] = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let dest = blobDownloads.removeValue(forKey: download) else { return }
        DownloadManager.shared.registerFinishedFile(dest, sourceURL: download.originalRequest?.url, pageURL: webView.url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        blobDownloads.removeValue(forKey: download)
        Toast.shared.show("التحميل فشل: \(error.localizedDescription)")
    }
}

// MARK: - UI delegate (new windows, long-press menu, JS dialogs)

extension BrowserTab: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if let open = onOpenInNewTab { open(url) } else { webView.load(navigationAction.request) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else {
            completionHandler(nil)
            return
        }
        let config = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(title: url.absoluteString, children: [
                UIAction(title: "فتح", image: UIImage(systemName: "arrow.up.forward.square")) { _ in
                    self?.webView.load(URLRequest(url: url))
                },
                UIAction(title: "فتح في تبويب جديد", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    self?.onOpenInNewTab?(url)
                },
                UIAction(title: "تحميل بـ NileDM", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    self?.download(url: url)
                },
                UIAction(title: "نسخ الرابط", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = url
                    Toast.shared.show("الرابط اتنسخ")
                },
            ])
        }
        completionHandler(config)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "تمام", style: .default) { _ in completionHandler() })
        if let top = UIApplication.shared.topViewController { top.present(a, animated: true) } else { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "إلغاء", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "تمام", style: .default) { _ in completionHandler(true) })
        if let top = UIApplication.shared.topViewController { top.present(a, animated: true) } else { completionHandler(false) }
    }
}

// MARK: - Tabs

final class TabsModel: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var currentID: UUID?

    init() {
        newTab(nil)
    }

    var current: BrowserTab {
        tabs.first { $0.id == currentID } ?? tabs[0]
    }

    func newTab(_ url: URL?) {
        let t = BrowserTab(url: url)
        t.onOpenInNewTab = { [weak self] u in self?.newTab(u) }
        tabs.append(t)
        currentID = t.id
    }

    func close(_ tab: BrowserTab) {
        tabs.removeAll { $0.id == tab.id }
        if tabs.isEmpty { newTab(nil) }
        if currentID == tab.id || !tabs.contains(where: { $0.id == currentID }) { currentID = tabs.last?.id }
    }
}
