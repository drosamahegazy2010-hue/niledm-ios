import Foundation
import UIKit
import UserNotifications

// MARK: - Paths

enum Paths {
    static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// Finished files live here. Visible in the Files app: On My iPhone › NileDM › Downloads
    static var downloads: URL {
        let u = documents.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let u = base.appendingPathComponent("NileDM", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var resume: URL {
        let u = support.appendingPathComponent("resume", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// "name.ext", or "name (1).ext", "name (2).ext"... if it already exists.
    static func unique(_ name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var candidate = dir.appendingPathComponent(name)
        var i = 1
        while fm.fileExists(atPath: candidate.path) {
            let n = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            candidate = dir.appendingPathComponent(n)
            i += 1
        }
        return candidate
    }

    /// Paths inside the app container change between installs, so store them relative to home.
    static func relativeToHome(_ url: URL) -> String {
        let p = url.path
        let h = home.path
        if p.hasPrefix(h) {
            return String(p.dropFirst(h.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return url.relativePath
    }

    static func fromHome(_ rel: String) -> URL {
        home.appendingPathComponent(rel)
    }
}

// MARK: - File names

enum FileNames {
    static func sanitize(_ raw: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t").union(.controlCharacters)
        var s = raw.components(separatedBy: bad).joined(separator: "_")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if s.isEmpty { s = "download" }
        if s.count > 150 {
            let ext = (s as NSString).pathExtension
            let stem = String((s as NSString).deletingPathExtension.prefix(140))
            s = ext.isEmpty || ext.count > 8 ? stem : "\(stem).\(ext)"
        }
        return s
    }

    static func ext(of url: URL) -> String {
        url.pathExtension.lowercased()
    }

    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv", "avi", "3gp", "ts", "movpkg"]
    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus"]
    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp"]
    static let docExts: Set<String> = ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "epub", "rtf", "csv"]
    static let archiveExts: Set<String> = ["zip", "rar", "7z", "tar", "gz"]

    static func symbol(for name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        if videoExts.contains(e) { return "film" }
        if audioExts.contains(e) { return "music.note" }
        if imageExts.contains(e) { return "photo" }
        if docExts.contains(e) { return "doc.text" }
        if archiveExts.contains(e) { return "archivebox" }
        if e == "apk" || e == "ipa" || e == "exe" { return "app.badge" }
        return "doc"
    }
}

// MARK: - Formatting

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        if n < 0 { return "؟" }
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func speed(_ bps: Double) -> String {
        bps > 1 ? ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/ث" : ""
    }

    static func eta(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let t = Int(seconds)
        if t >= 3600 { return String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60) }
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ar")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

// MARK: - Cookies

enum Cookies {
    /// Cookie header for `url`, built from the web view's cookies (domain-matched).
    static func header(_ cookies: [HTTPCookie], for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return "" }
        let path = url.path.isEmpty ? "/" : url.path
        let matching = cookies.filter { c in
            var d = c.domain.lowercased()
            if d.hasPrefix(".") { d.removeFirst() }
            let domainOK = host == d || host.hasSuffix("." + d)
            let pathOK = path.hasPrefix(c.path.isEmpty ? "/" : c.path)
            let secureOK = !c.isSecure || url.scheme?.lowercased() == "https"
            let fresh = c.expiresDate.map { $0 > Date() } ?? true
            return domainOK && pathOK && secureOK && fresh
        }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(title: String, body: String, id: String = UUID().uuidString, at date: Date? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var trigger: UNNotificationTrigger?
        if let date, date > Date() {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)
        }
        let req = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

// MARK: - Sideload expiry (free Apple ID apps must be refreshed every 7 days)

enum Provision {
    static let expiry: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        let plistText = String(text[start.lowerBound..<end.upperBound])
        guard let plistData = plistText.data(using: .isoLatin1),
              let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }()

    /// Remind the user one day before the app stops opening.
    static func scheduleReminder() {
        guard let exp = expiry else { return }
        let when = exp.addingTimeInterval(-24 * 3600)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["expiry"])
        Notifier.post(title: "NileDM محتاج تجديد بكرة",
                      body: "وصّل الآيفون بالكمبيوتر وجدّد البرنامج من Sideloadly علشان يفضل شغال.",
                      id: "expiry", at: when)
    }
}

// MARK: - Toasts

final class Toast: ObservableObject {
    static let shared = Toast()
    @Published var message: String?
    private var work: DispatchWorkItem?

    func show(_ text: String) {
        DispatchQueue.main.async {
            self.message = text
            self.work?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.message = nil }
            self.work = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: w)
        }
    }
}

// MARK: - UIKit helpers

extension UIApplication {
    var topViewController: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
