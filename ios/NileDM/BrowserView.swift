import SwiftUI
import WebKit

struct BrowserScreen: View {
    @EnvironmentObject var tabs: TabsModel

    var body: some View {
        BrowserTabView(tab: tabs.current)
            .id(tabs.current.id)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct BrowserTabView: View {
    @EnvironmentObject var tabs: TabsModel
    @ObservedObject var tab: BrowserTab
    @AppStorage("videoQuality") private var quality = "best"
    @State private var address = ""
    @FocusState private var editing: Bool
    @State private var showMedia = false
    @State private var showTabs = false

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            ZStack(alignment: .top) {
                WebViewContainer(webView: tab.webView)
                if tab.isLoading {
                    ProgressView(value: tab.progress)
                        .progressViewStyle(.linear)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !tab.visibleMedia.isEmpty {
                    Button { showMedia = true } label: {
                        Label(tr("تحميل الفيديو (\(tab.visibleMedia.count))", "Download video (\(tab.visibleMedia.count))"), systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Capsule().fill(Color.accentColor))
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                    }
                    .padding(14)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: tab.visibleMedia.count)
            toolbar
        }
        .sheet(isPresented: $showMedia) { MediaSheet(tab: tab, quality: quality) }
        .onReceive(NotificationCenter.default.publisher(for: .init("NDMShowMedia"))) { _ in showMedia = true }
        .sheet(isPresented: $showTabs) { TabsSheet() }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: tab.urlString.hasPrefix("https") ? "lock.fill" : "globe")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField(tr("اكتب رابط أو دوّر على جوجل", "Type a link or search Google"), text: $address)
                .focused($editing)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    tab.open(address)
                    editing = false
                }
            if editing {
                Button(tr("إلغاء", "Cancel")) { editing = false }
                    .font(.subheadline)
            } else {
                Button { tab.reloadOrStop() } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }
                .font(.subheadline)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .onAppear { address = tab.displayHost }
        .onChange(of: editing) { isEditing in
            address = isEditing ? tab.urlString : tab.displayHost
        }
        .onChange(of: tab.urlString) { _ in
            if !editing { address = tab.displayHost }
        }
    }

    private var toolbar: some View {
        HStack {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!tab.canGoBack)
            Spacer()
            Button { tab.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!tab.canGoForward)
            Spacer()
            Button { showMedia = true } label: {
                Image(systemName: tab.visibleMedia.isEmpty ? "arrow.down.circle" : "arrow.down.circle.fill")
            }
            Spacer()
            Button { tabs.newTab(nil) } label: { Image(systemName: "plus") }
            Spacer()
            Button { showTabs = true } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.8).frame(width: 23, height: 23)
                    Text("\(tabs.tabs.count)").font(.caption.weight(.bold))
                }
            }
        }
        .font(.title3)
        .padding(.horizontal, 24)
        .padding(.vertical, 9)
        .background(.bar)
    }
}

// MARK: - Detected media

struct MediaSheet: View {
    @ObservedObject var tab: BrowserTab
    let quality: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if tab.visibleMedia.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(tr("مفيش فيديو اتلقط في الصفحة دي لسه", "No video found on this page yet")).font(.headline)
                            Text(tr("شغّل الفيديو كام ثانية وهيظهر هنا لوحده. فيديوهات يوتيوب ونتفليكس والبث المباشر مش مدعومة.", "Play the video for a few seconds and it will show up here. YouTube, Netflix and live streams aren't supported."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section(tr("الفيديوهات والملفات اللي اتلقطت", "Videos and files found")) {
                        ForEach(tab.visibleMedia) { m in
                            MediaRow(media: m) { variant in
                                tab.download(media: m, quality: quality, variant: variant)
                                dismiss()
                            }
                        }
                    }
                }
                Section {
                    Button {
                        if let u = tab.webView.url { tab.download(url: u) }
                        dismiss()
                    } label: {
                        Label(tr("حمّل الصفحة المفتوحة كملف", "Download the open page as a file"), systemImage: "arrow.down.doc")
                    }
                } footer: {
                    Text(tr("مفيد لو فاتح ملف PDF أو فيديو مباشر. وتقدر كمان تدوس ضغطة طويلة على أي رابط وتختار «تحميل بـ NileDM».", "Handy when a PDF or a direct video is open. You can also long-press any link and choose “Download with NileDM”."))
                }
            }
            .navigationTitle(tr("تحميل من الصفحة", "Download from page"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("قفل", "Close")) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct MediaRow: View {
    let media: MediaItem
    let onDownload: (HLSVariant?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(media.badge)
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if media.size > 0 {
                        Text(Fmt.bytes(media.size)).font(.caption).foregroundStyle(.secondary)
                    } else if media.isMaster {
                        Text(tr("فيديو بث • \(media.variants.count) جودة", "Stream • \(media.variants.count) qualities")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(tr("تحميل", "Download")) { onDownload(nil) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if media.variants.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(media.variants, id: \.self) { v in
                            Button(v.label) { onDownload(v) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 4)
    }
}

// MARK: - Tabs list

struct TabsSheet: View {
    @EnvironmentObject var tabs: TabsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(tabs.tabs) { t in
                    TabRow(tab: t, isCurrent: t.id == tabs.currentID) {
                        tabs.currentID = t.id
                        dismiss()
                    } onClose: {
                        tabs.close(t)
                    }
                }
            }
            .navigationTitle(tr("التبويبات", "Tabs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        tabs.newTab(nil)
                        dismiss()
                    } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .cancellationAction) { Button(tr("تم", "Done")) { dismiss() } }
            }
        }
    }
}

struct TabRow: View {
    @ObservedObject var tab: BrowserTab
    let isCurrent: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(tab.title.isEmpty ? tr("صفحة جديدة", "New page") : tab.title)
                    .font(.subheadline.weight(isCurrent ? .bold : .regular))
                    .lineLimit(1)
                Text(tab.displayHost).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
