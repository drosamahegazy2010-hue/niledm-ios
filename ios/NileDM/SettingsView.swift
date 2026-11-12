import SwiftUI
import WebKit

struct SettingsScreen: View {
    @EnvironmentObject var dm: DownloadManager
    @AppStorage("videoQuality") private var quality = "best"

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("الجودة الافتراضية", selection: $quality) {
                        Text("أعلى جودة").tag("best")
                        Text("1080p").tag("1080")
                        Text("720p").tag("720")
                        Text("480p").tag("480")
                        Text("360p").tag("360")
                    }
                } header: {
                    Text("الفيديو")
                } footer: {
                    Text("بتتطبق لما تدوس «تحميل» على فيديو بث. وتقدر تختار جودة معينة من الأزرار اللي تحت اسم الفيديو.")
                }

                Section {
                    Label("التحميل بيكمل وانت في برنامج تاني أو الشاشة مقفولة، وبيوصلك إشعار لما يخلص.", systemImage: "checkmark.circle")
                    Label("متقفلش NileDM بالسحب لفوق من قايمة البرامج المفتوحة — ده الشيء الوحيد اللي بيوقف التحميل (iOS بيعمل كده مع كل البرامج). لو حصل، افتح البرنامج ودوس استكمال.", systemImage: "exclamationmark.triangle")
                    Label("التحميل بيشتغل على الواي فاي وبيانات الموبايل.", systemImage: "antenna.radiowaves.left.and.right")
                } header: {
                    Text("التحميل في الخلفية")
                }

                Section {
                    Text("برنامج «الملفات» (Files) ← على الآيفون ← NileDM ← Downloads")
                    Button {
                        if let u = URL(string: "shareddocuments://" + Paths.downloads.path) { UIApplication.shared.open(u) }
                    } label: {
                        Label("افتح الفولدر في برنامج الملفات", systemImage: "folder")
                    }
                } header: {
                    Text("مكان الملفات")
                }

                Section {
                    Button(role: .destructive) {
                        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                                modifiedSince: .distantPast) {
                            Toast.shared.show("اتمسحت بيانات التصفح")
                        }
                    } label: {
                        Label("مسح بيانات التصفح (الكوكيز والكاش)", systemImage: "trash")
                    }
                    Button { dm.clearFinished() } label: {
                        Label("شيل التحميلات المكتملة من القايمة (الملفات بتفضل)", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("المتصفح")
                }

                Section {
                    LabeledContent("الإصدار", value: version)
                    if let exp = Provision.expiry {
                        LabeledContent("محتاج تجديد قبل", value: Fmt.date(exp))
                        Text("بحساب Apple المجاني البرنامج بيشتغل 7 أيام. جدّده من Sideloadly على الكمبيوتر قبل الميعاد ده (هيوصلك تنبيه قبلها بيوم). التحميلات والملفات مش بتتمسح مع التجديد.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("عن NileDM")
                }
            }
            .navigationTitle("الإعدادات")
        }
    }
}
