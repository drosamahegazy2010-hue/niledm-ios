import AVKit
import Photos
import QuickLook
import SwiftUI

struct OpenFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct DownloadsScreen: View {
    @EnvironmentObject var dm: DownloadManager
    @State private var showAdd = false
    @State private var newLink = ""
    @State private var playing: OpenFile?
    @State private var previewing: OpenFile?

    var body: some View {
        NavigationStack {
            Group {
                if dm.items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(dm.items) { item in
                            DownloadRow(item: item) { open(item) }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { dm.delete(item.id) } label: {
                                        Label(tr("حذف", "Delete"), systemImage: "trash")
                                    }
                                }
                                .contextMenu { menu(for: item) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(tr("التحميلات", "Downloads"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newLink = ""
                        showAdd = true
                    } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .cancellationAction) {
                    if dm.items.contains(where: { $0.state == .completed }) {
                        Button(tr("مسح المكتمل", "Clear finished")) { dm.clearFinished() }
                    }
                }
            }
            .alert(tr("تحميل رابط", "Download a link"), isPresented: $showAdd) {
                TextField("https://...", text: $newLink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button(tr("تحميل", "Download")) { addLink() }
                Button(tr("إلغاء", "Cancel"), role: .cancel) {}
            } message: {
                Text(tr("الصق رابط ملف أو فيديو (mp4 أو m3u8)", "Paste a link to a file or video (mp4 or m3u8)"))
            }
            .fullScreenCover(item: $playing) { f in PlayerScreen(url: f.url) }
            .sheet(item: $previewing) { f in QuickLookView(url: f.url).ignoresSafeArea() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 60))
                .foregroundStyle(Color.accentColor)
            Text(tr("مفيش تحميلات لسه", "No downloads yet")).font(.title3.weight(.bold))
            Text(tr("افتح أي موقع من «المتصفح»، شغّل الفيديو ودوس علامة التحميل اللي عليه، أو دوس ضغطة طويلة على أي رابط واختار «تحميل بـ NileDM».\nالتحميل بيكمل لوحده حتى لو خرجت من البرنامج.", "Open any site in “Browser”, play the video and tap the download button on it, or long-press any link and choose “Download with NileDM”.\nDownloads keep going even if you leave the app."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addLink() {
        let text = newLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let s = url.scheme?.lowercased(), s == "http" || s == "https" else {
            Toast.shared.show(tr("الرابط لازم يبدأ بـ http أو https", "The link must start with http or https"))
            return
        }
        var headers: [String: String] = [:]
        if let ua = BrowserTab.userAgent { headers["User-Agent"] = ua }
        dm.add(url: url, pageURL: nil, nameHint: nil, headers: headers)
    }

    private func open(_ item: DownloadItem) {
        guard item.state == .completed, let url = item.localURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Toast.shared.show(tr("الملف مش موجود (ممكن اتمسح من برنامج الملفات)", "File not found (it may have been deleted in the Files app)"))
            return
        }
        if item.isVideo || item.isAudio {
            playing = OpenFile(url: url)
        } else {
            previewing = OpenFile(url: url)
        }
    }

    @ViewBuilder
    private func menu(for item: DownloadItem) -> some View {
        if item.state == .completed, let url = item.localURL {
            Button { open(item) } label: { Label(tr("فتح", "Open"), systemImage: "play.circle") }
            if item.fileName != nil {
                ShareLink(item: url) { Label(tr("مشاركة / حفظ في الملفات", "Share / Save to Files"), systemImage: "square.and.arrow.up") }
                if item.isVideo || FileNames.imageExts.contains(url.pathExtension.lowercased()) {
                    Button { saveToPhotos(url) } label: { Label(tr("حفظ في الصور", "Save to Photos"), systemImage: "photo.on.rectangle") }
                }
            }
        }
        if item.state == .downloading {
            Button { dm.pause(item.id) } label: { Label(tr("إيقاف مؤقت", "Pause"), systemImage: "pause.circle") }
        }
        if item.state == .paused || item.state == .failed {
            Button { dm.resume(item.id) } label: { Label(tr("استكمال", "Resume"), systemImage: "arrow.clockwise.circle") }
        }
        Button {
            UIPasteboard.general.string = item.url
            Toast.shared.show(tr("الرابط اتنسخ", "Link copied"))
        } label: { Label(tr("نسخ الرابط", "Copy link"), systemImage: "doc.on.doc") }
        Button(role: .destructive) { dm.delete(item.id) } label: { Label(tr("حذف", "Delete"), systemImage: "trash") }
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Toast.shared.show(tr("اسمح لـ NileDM بالحفظ في الصور من الإعدادات", "Allow NileDM to add to Photos in the Settings app"))
                return
            }
            let isImage = FileNames.imageExts.contains(url.pathExtension.lowercased())
            PHPhotoLibrary.shared().performChanges({
                if isImage {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                } else {
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            }) { ok, error in
                Toast.shared.show(ok ? tr("اتحفظ في الصور ✔", "Saved to Photos ✔") : tr("الصور مش بتقبل الملف ده: \(error?.localizedDescription ?? "")", "Photos can't take this file: \(error?.localizedDescription ?? "")"))
            }
        }
    }
}

struct DownloadRow: View {
    let item: DownloadItem
    let onOpen: () -> Void
    @EnvironmentObject var dm: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Color.accentColor.opacity(0.13))
                Image(systemName: item.kind == .hls ? "film" : FileNames.symbol(for: item.fileName ?? item.title))
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if item.state != .completed {
                    if item.state == .processing {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: min(max(item.progress, 0), 1))
                            .tint(item.state == .failed ? .red : item.state == .paused ? .orange : Color.accentColor)
                    }
                }
                Text(status)
                    .font(.caption)
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            actionButton
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch item.state {
        case .downloading:
            Button { dm.pause(item.id) } label: { Image(systemName: "pause.circle.fill").font(.title) }
                .buttonStyle(.borderless)
        case .paused, .failed:
            Button { dm.resume(item.id) } label: {
                Image(systemName: item.state == .failed ? "arrow.clockwise.circle.fill" : "play.circle.fill").font(.title)
            }
            .buttonStyle(.borderless)
        case .completed:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .processing:
            EmptyView()
        }
    }

    private var status: String {
        let pct = "\(Int((item.progress * 100).rounded()))%"
        let sizes = item.total > 0 ? tr("\(Fmt.bytes(item.received)) من \(Fmt.bytes(item.total))", "\(Fmt.bytes(item.received)) of \(Fmt.bytes(item.total))") : Fmt.bytes(item.received)
        switch item.state {
        case .downloading:
            var parts = [pct, sizes]
            let sp = Fmt.speed(item.speed)
            if !sp.isEmpty { parts.append(sp) }
            let eta = Fmt.eta(item.eta)
            if !eta.isEmpty { parts.append(tr("باقي \(eta)", "\(eta) left")) }
            return parts.joined(separator: " • ")
        case .processing:
            return tr("بيجهّز الفيديو MP4...", "Preparing the MP4 video...")
        case .paused:
            return [tr("متوقف • \(pct) • \(sizes)", "Paused • \(pct) • \(sizes)"), item.error].compactMap { $0 }.joined(separator: "\n")
        case .failed:
            return item.error ?? tr("فشل", "Failed")
        case .completed:
            var parts: [String] = []
            if item.total > 0 { parts.append(Fmt.bytes(item.total)) }
            if let f = item.finished { parts.append(Fmt.date(f)) }
            var s = parts.joined(separator: " • ")
            if let e = item.error { s += "\n" + e }
            return s
        }
    }
}

// MARK: - Player & previews

struct PlayerScreen: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            PlayerView(url: url).ignoresSafeArea()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
            }
            .padding()
        }
        .background(Color.black)
    }
}

struct PlayerView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        vc.player?.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
    }
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
