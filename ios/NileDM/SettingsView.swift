import SwiftUI
import WebKit

struct SettingsScreen: View {
    @EnvironmentObject var dm: DownloadManager
    @EnvironmentObject var tabs: TabsModel
    @AppStorage("videoQuality") private var quality = "best"
    @AppStorage(L10n.key) private var lang = "ar"
    @AppStorage("videoButtons") private var videoButtons = true

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Language", selection: $lang) {
                        Text("العربية").tag("ar")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("اللغة • Language")
                }

                Section {
                    Toggle(isOn: $videoButtons) {
                        Label(tr("علامة تحميل على كل فيديو", "Download button on every video"), systemImage: "arrow.down.circle")
                    }
                    .onChange(of: videoButtons) { _ in tabs.applyButtonSetting() }
                    Picker(tr("الجودة الافتراضية", "Default quality"), selection: $quality) {
                        Text(tr("أعلى جودة", "Best quality")).tag("best")
                        Text("1080p").tag("1080")
                        Text("720p").tag("720")
                        Text("480p").tag("480")
                        Text("360p").tag("360")
                    }
                } header: {
                    Text(tr("الفيديو", "Video"))
                } footer: {
                    Text(tr("العلامة بتظهر فوق كل فيديو في الصفحة، دوسة واحدة عليها بتبدأ التحميل بالجودة دي. ولو الصفحة فيها كذا فيديو بث، هتختار منهم.", "The button shows on top of every video in the page; one tap starts the download in this quality. If the page has several streams, you pick one."))
                }

                Section {
                    Label(tr("التحميل بيكمل وانت في برنامج تاني أو الشاشة مقفولة، وبيوصلك إشعار لما يخلص.", "Downloads keep going while you're in another app or the screen is locked, and you get a notification when they finish."), systemImage: "checkmark.circle")
                    Label(tr("متقفلش NileDM بالسحب لفوق من قايمة البرامج المفتوحة — ده الشيء الوحيد اللي بيوقف التحميل (iOS بيعمل كده مع كل البرامج). لو حصل، افتح البرنامج ودوس استكمال.", "Don't swipe NileDM away in the app switcher — that's the only thing that stops downloads (iOS does this to every app). If it happens, open the app and tap Resume."), systemImage: "exclamationmark.triangle")
                    Label(tr("التحميل بيشتغل على الواي فاي وبيانات الموبايل.", "Downloads work on Wi-Fi and mobile data."), systemImage: "antenna.radiowaves.left.and.right")
                } header: {
                    Text(tr("التحميل في الخلفية", "Background downloads"))
                }

                Section {
                    Text(tr("برنامج «الملفات» (Files) ← على الآيفون ← NileDM ← Downloads", "Files app → On My iPhone → NileDM → Downloads"))
                    Button {
                        if let u = URL(string: "shareddocuments://" + Paths.downloads.path) { UIApplication.shared.open(u) }
                    } label: {
                        Label(tr("افتح الفولدر في برنامج الملفات", "Open the folder in Files"), systemImage: "folder")
                    }
                } header: {
                    Text(tr("مكان الملفات", "Where files are saved"))
                }

                Section {
                    Button(role: .destructive) {
                        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                                modifiedSince: .distantPast) {
                            Toast.shared.show(tr("اتمسحت بيانات التصفح", "Browsing data cleared"))
                        }
                    } label: {
                        Label(tr("مسح بيانات التصفح (الكوكيز والكاش)", "Clear browsing data (cookies and cache)"), systemImage: "trash")
                    }
                    Button { dm.clearFinished() } label: {
                        Label(tr("شيل التحميلات المكتملة من القايمة (الملفات بتفضل)", "Remove finished downloads from the list (the files stay)"), systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text(tr("المتصفح", "Browser"))
                }

                Section {
                    LabeledContent(tr("الإصدار", "Version"), value: version)
                    if let exp = Provision.expiry {
                        LabeledContent(tr("محتاج تجديد قبل", "Renew before"), value: Fmt.date(exp))
                        Text(tr("بحساب Apple المجاني البرنامج بيشتغل 7 أيام. جدّده من Sideloadly على الكمبيوتر قبل الميعاد ده (هيوصلك تنبيه قبلها بيوم). التحميلات والملفات مش بتتمسح مع التجديد.", "With a free Apple account the app works for 7 days. Renew it with Sideloadly on your computer before this date (you'll get a reminder a day before). Renewing doesn't delete your downloads."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(tr("عن NileDM", "About NileDM"))
                }
            }
            .navigationTitle(tr("الإعدادات", "Settings"))
        }
    }
}
