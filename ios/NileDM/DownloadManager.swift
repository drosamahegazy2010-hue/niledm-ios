import AVFoundation
import Foundation
import UIKit

/// All downloads go through iOS *background* sessions: the system keeps transferring after you
/// leave the app (or iOS suspends it) and wakes NileDM up when they finish.
/// Normal files -> URLSession (pause/resume with resume data).
/// m3u8 streams -> AVAssetDownloadURLSession, then converted to a normal MP4 in Downloads.
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    static let fileSessionID = "com.niledm.browser.files"
    static let hlsSessionID = "com.niledm.browser.hls"
    static let fgSessionID = "fg"   // ordinary session, only used if the background service refuses a download

    @Published private(set) var items: [DownloadItem] = []

    private var store: [DownloadItem] = []          // source of truth (guarded by lock)
    private let lock = NSLock()
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "niledm.downloads"
        return q
    }()
    private let saveQueue = DispatchQueue(label: "niledm.save")
    private var fileSession: URLSession!
    private var hlsSession: AVAssetDownloadURLSession!
    private var fgSession: URLSession!
    private var fallbackTried = Set<String>()       // item ids already retried on the ordinary session
    private var backgroundHandlers: [String: () -> Void] = [:]
    private var cancelledTasks = Set<String>()       // "<session>#<taskIdentifier>" we cancelled on purpose
    private var speedSamples: [String: (bytes: Int64, time: Date)] = [:]
    private var publishScheduled = false
    private var lastSave = Date.distantPast

    private override init() {
        super.init()
        load()

        let fc = URLSessionConfiguration.background(withIdentifier: Self.fileSessionID)
        fc.sessionSendsLaunchEvents = true
        fc.isDiscretionary = false
        fc.allowsCellularAccess = true
        fc.httpMaximumConnectionsPerHost = 6
        fileSession = URLSession(configuration: fc, delegate: self, delegateQueue: delegateQueue)

        let hc = URLSessionConfiguration.background(withIdentifier: Self.hlsSessionID)
        hc.sessionSendsLaunchEvents = true
        hc.isDiscretionary = false
        hc.allowsCellularAccess = true
        hlsSession = AVAssetDownloadURLSession(configuration: hc, assetDownloadDelegate: self, delegateQueue: delegateQueue)

        let gc = URLSessionConfiguration.default
        gc.httpMaximumConnectionsPerHost = 6
        fgSession = URLSession(configuration: gc, delegate: self, delegateQueue: delegateQueue)

        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.saveNow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.reconcile() }
    }

    // MARK: Public API (call on main)

    var activeCount: Int { items.filter { $0.isActive }.count }

    /// Picks the right engine from the URL.
    func add(url: URL, pageURL: URL?, nameHint: String?, headers: [String: String], quality: String = "best") {
        if url.pathExtension.lowercased() == "m3u8" {
            let title = (nameHint as NSString?)?.deletingPathExtension ?? url.deletingPathExtension().lastPathComponent
            addHLS(url: url, pageURL: pageURL, title: title, bitrate: nil, headers: headers)
        } else {
            addFile(url: url, pageURL: pageURL, nameHint: nameHint, headers: headers)
        }
    }

    func addFile(url: URL, pageURL: URL?, nameHint: String?, headers: [String: String]) {
        let fallback = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        let title = nameHint ?? (fallback.isEmpty ? (url.host ?? "download") : fallback)
        let item = DownloadItem(id: UUID().uuidString, kind: .file, url: url.absoluteString,
                                pageURL: pageURL?.absoluteString, title: title, nameHint: nameHint,
                                state: .downloading, created: Date(), headers: headers)
        insert(item)
        startFileTask(item)
        Toast.shared.show("بدأ التحميل ⬇")
    }

    func addHLS(url: URL, pageURL: URL?, title: String, bitrate: Double?, headers: [String: String]) {
        var clean = FileNames.sanitize(title)
        if clean.lowercased() == "index" || clean.lowercased() == "master" || clean.lowercased() == "playlist" {
            clean = "فيديو " + Fmt.date(Date())
        }
        let item = DownloadItem(id: UUID().uuidString, kind: .hls, url: url.absoluteString,
                                pageURL: pageURL?.absoluteString, title: clean, nameHint: nil,
                                state: .downloading, created: Date(), headers: headers, bitrate: bitrate)
        insert(item)
        startHLSTask(item)
        Toast.shared.show("بدأ تحميل الفيديو ⬇")
    }

    func pause(_ id: String) {
        guard let it = item(id), it.state == .downloading else { return }
        mutate(id, now: true) { $0.state = .paused; $0.speed = 0; $0.eta = 0 }
        if it.kind == .file {
            for (session, sid) in [(fileSession!, Self.fileSessionID), (fgSession!, Self.fgSessionID)] {
                session.getAllTasks { tasks in
                    for case let t as URLSessionDownloadTask in tasks where t.taskDescription == id {
                        self.markCancelled(t, in: sid)
                        t.cancel(byProducingResumeData: { data in
                            if let data { try? data.write(to: self.resumeURL(id), options: .atomic) }
                        })
                    }
                }
            }
        } else {
            hlsSession.getAllTasks { tasks in
                tasks.filter { $0.taskDescription == id }.forEach { $0.suspend() }
            }
        }
    }

    func resume(_ id: String) {
        guard let it = item(id), it.state == .paused || it.state == .failed else { return }
        mutate(id, now: true) { $0.state = .downloading; $0.error = nil }
        if it.kind == .file {
            // give a just-cancelled task a moment to hand over its resume data
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.startFileTask(it) }
        } else {
            hlsSession.getAllTasks { tasks in
                let mine = tasks.filter { $0.taskDescription == id }
                if mine.isEmpty || it.state == .failed {
                    mine.forEach { self.markCancelled($0, in: Self.hlsSessionID); $0.cancel() }
                    self.startHLSTask(it)
                } else {
                    mine.forEach { $0.resume() }
                }
            }
        }
    }

    func delete(_ id: String) {
        guard let it = item(id) else { return }
        let cancel: (String) -> ([URLSessionTask]) -> Void = { sid in
            { tasks in
                for t in tasks where t.taskDescription == id {
                    self.markCancelled(t, in: sid)
                    t.cancel()
                }
            }
        }
        fileSession.getAllTasks(completionHandler: cancel(Self.fileSessionID))
        fgSession.getAllTasks(completionHandler: cancel(Self.fgSessionID))
        hlsSession.getAllTasks(completionHandler: cancel(Self.hlsSessionID))
        lock.lock()
        store.removeAll { $0.id == id }
        lock.unlock()
        publish(now: true)
        try? FileManager.default.removeItem(at: resumeURL(id))
        if let f = it.fileName { try? FileManager.default.removeItem(at: Paths.downloads.appendingPathComponent(f)) }
        if let a = it.assetPath { try? FileManager.default.removeItem(at: Paths.fromHome(a)) }
    }

    /// A file WebKit saved by itself (blob:/data: links) — just list it.
    func registerFinishedFile(_ file: URL, sourceURL: URL?, pageURL: URL?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        var item = DownloadItem(id: UUID().uuidString, kind: .file, url: sourceURL?.absoluteString ?? file.absoluteString,
                                pageURL: pageURL?.absoluteString, title: file.lastPathComponent, nameHint: nil,
                                state: .completed, created: Date())
        item.fileName = file.lastPathComponent
        item.progress = 1
        item.finished = Date()
        item.total = size
        item.received = size
        insert(item)
        notifyDone(file.lastPathComponent)
    }

    func clearFinished() {
        lock.lock()
        store.removeAll { $0.state == .completed }
        lock.unlock()
        publish(now: true)
    }

    func setBackgroundHandler(_ identifier: String, _ handler: @escaping () -> Void) {
        lock.lock()
        backgroundHandlers[identifier] = handler
        lock.unlock()
    }

    // MARK: Engines

    private func startFileTask(_ item: DownloadItem, ordinary: Bool = false) {
        let session: URLSession = ordinary ? fgSession : fileSession
        let task: URLSessionDownloadTask
        let rURL = resumeURL(item.id)
        if let data = try? Data(contentsOf: rURL) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: rURL)
        } else {
            guard let url = URL(string: item.url) else {
                fail(item.id, "الرابط مش صحيح")
                return
            }
            var req = URLRequest(url: url)
            for (k, v) in item.headers { req.setValue(v, forHTTPHeaderField: k) }
            task = session.downloadTask(with: req)
        }
        task.taskDescription = item.id
        task.resume()
    }

    private func startHLSTask(_ item: DownloadItem) {
        guard let url = URL(string: item.url) else {
            fail(item.id, "الرابط مش صحيح")
            return
        }
        var assetOptions: [String: Any] = [:]
        if !item.headers.isEmpty { assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = item.headers }
        let asset = AVURLAsset(url: url, options: assetOptions)
        var taskOptions: [String: Any]?
        if let br = item.bitrate, br > 0 {
            taskOptions = [AVAssetDownloadTaskMinimumRequiredMediaBitrateKey: NSNumber(value: br)]
        }
        guard let task = hlsSession.makeAssetDownloadTask(asset: asset, assetTitle: item.title,
                                                          assetArtworkData: nil, options: taskOptions) else {
            fail(item.id, "مقدرتش أبدأ تحميل الفيديو")
            return
        }
        task.taskDescription = item.id
        task.resume()
    }

    /// Turns the offline HLS package into a normal MP4 (playable anywhere, can go to Photos).
    private func exportMP4(_ id: String) {
        guard let it = item(id), let rel = it.assetPath else {
            fail(id, "ملف الفيديو مش موجود")
            return
        }
        let source = Paths.fromHome(rel)
        let asset = AVURLAsset(url: source)
        let dest = Paths.unique(FileNames.sanitize(it.title) + ".mp4", in: Paths.downloads)
        DispatchQueue.main.async {
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = UIApplication.shared.beginBackgroundTask(withName: "export") {
                UIApplication.shared.endBackgroundTask(bg)
                bg = .invalid
            }
            self.export(asset: asset, to: dest, presets: [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]) { ok in
                if ok {
                    try? FileManager.default.removeItem(at: source)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                    let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
                    self.mutate(id, now: true) { x in
                        x.fileName = dest.lastPathComponent
                        x.title = dest.lastPathComponent
                        x.assetPath = nil
                        x.state = .completed
                        x.finished = Date()
                        x.progress = 1
                        x.error = nil
                        if size > 0 { x.total = size; x.received = size }
                    }
                } else {
                    // The offline package still plays inside NileDM.
                    self.mutate(id, now: true) { x in
                        x.state = .completed
                        x.finished = Date()
                        x.progress = 1
                        x.error = "اتحفظ للمشاهدة جوه البرنامج بس (مقدرتش أحوّله MP4)"
                    }
                }
                self.notifyDone(it.title)
                DispatchQueue.main.async {
                    if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
                }
            }
        }
    }

    private func export(asset: AVAsset, to dest: URL, presets: [String], done: @escaping (Bool) -> Void) {
        guard let preset = presets.first else { done(false); return }
        let rest = Array(presets.dropFirst())
        guard let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(.mp4) else {
            export(asset: asset, to: dest, presets: rest, done: done)
            return
        }
        session.outputURL = dest
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            if session.status == .completed {
                done(true)
            } else {
                try? FileManager.default.removeItem(at: dest)
                self.export(asset: asset, to: dest, presets: rest, done: done)
            }
        }
    }

    // MARK: Store helpers

    private func item(_ id: String) -> DownloadItem? {
        lock.lock()
        defer { lock.unlock() }
        return store.first { $0.id == id }
    }

    private func insert(_ item: DownloadItem) {
        lock.lock()
        store.insert(item, at: 0)
        lock.unlock()
        publish(now: true)
    }

    private func mutate(_ id: String, now: Bool = false, _ change: (inout DownloadItem) -> Void) {
        lock.lock()
        if let i = store.firstIndex(where: { $0.id == id }) { change(&store[i]) }
        lock.unlock()
        publish(now: now)
    }

    private func fail(_ id: String, _ message: String) {
        mutate(id, now: true) { x in
            x.state = .failed
            x.error = message
            x.speed = 0
            x.eta = 0
        }
        let title = item(id)?.title ?? ""
        DispatchQueue.main.async {
            if UIApplication.shared.applicationState != .active {
                Notifier.post(title: "التحميل وقف", body: "\(title)\n\(message)")
            }
        }
    }

    private func notifyDone(_ name: String) {
        DispatchQueue.main.async {
            if UIApplication.shared.applicationState != .active {
                Notifier.post(title: "اكتمل التحميل ✔", body: name)
            } else {
                Toast.shared.show("اكتمل: \(name)")
            }
        }
    }

    private func markCancelled(_ task: URLSessionTask, in session: String) {
        lock.lock()
        cancelledTasks.insert("\(session)#\(task.taskIdentifier)")
        lock.unlock()
    }

    private func wasCancelledByUs(_ task: URLSessionTask, in session: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledTasks.remove("\(session)#\(task.taskIdentifier)") != nil
    }

    private func resumeURL(_ id: String) -> URL {
        Paths.resume.appendingPathComponent(id + ".data")
    }

    /// Speed over windows of at least 1 s. Called on the (serial) delegate queue only.
    private func sample(_ id: String, bytes: Int64, total: Int64) -> (speed: Double?, eta: Double) {
        let now = Date()
        guard let last = speedSamples[id] else {
            speedSamples[id] = (bytes, now)
            return (nil, 0)
        }
        let dt = now.timeIntervalSince(last.time)
        guard dt >= 1 else { return (nil, 0) }
        speedSamples[id] = (bytes, now)
        let s = Double(max(0, bytes - last.bytes)) / dt
        let eta = (total > 0 && s > 0) ? Double(total - bytes) / s : 0
        return (s, eta)
    }

    private func friendly(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorNotConnectedToInternet: return "مفيش إنترنت — دوس استكمال لما النت يرجع"
        case NSURLErrorTimedOut: return "السيرفر مبيردش — جرّب تاني"
        case NSURLErrorNetworkConnectionLost: return "الاتصال اتقطع — دوس استكمال"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "مش قادر أوصل للموقع"
        default:
            let under = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).map { " / \($0.code)" } ?? ""
            return "\(ns.localizedDescription) [\(ns.code)\(under)]"
        }
    }

    // MARK: Persistence

    private var dbURL: URL { Paths.support.appendingPathComponent("downloads.json") }

    private func load() {
        guard let data = try? Data(contentsOf: dbURL),
              let list = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        store = list
        items = list
    }

    private func publish(now: Bool = false) {
        lock.lock()
        if publishScheduled && !now {
            lock.unlock()
            return
        }
        publishScheduled = true
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + (now ? 0 : 0.35)) {
            self.lock.lock()
            let snapshot = self.store
            self.publishScheduled = false
            self.lock.unlock()
            self.items = snapshot
            if now || Date().timeIntervalSince(self.lastSave) > 2 {
                self.lastSave = Date()
                self.saveQueue.async { self.write(snapshot) }
            }
        }
    }

    private func saveNow() {
        lock.lock()
        let snapshot = store
        lock.unlock()
        saveQueue.sync { write(snapshot) }
    }

    private func write(_ snapshot: [DownloadItem]) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: dbURL, options: .atomic)
        }
    }

    /// After a relaunch: find downloads whose task no longer exists and fix their state.
    private func reconcile() {
        let sessions: [URLSession] = [fileSession, fgSession, hlsSession]
        let group = DispatchGroup()
        let liveLock = NSLock()
        var live = Set<String>()
        for s in sessions {
            group.enter()
            s.getAllTasks { tasks in
                liveLock.lock()
                for t in tasks { if let d = t.taskDescription { live.insert(d) } }
                liveLock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.lock.lock()
            let snapshot = self.store
            self.lock.unlock()
            for it in snapshot {
                if it.state == .processing {
                    self.exportMP4(it.id)
                    continue
                }
                guard it.state == .downloading, !live.contains(it.id) else { continue }
                if it.kind == .hls, it.assetPath != nil {
                    self.mutate(it.id, now: true) { $0.state = .processing }
                    self.exportMP4(it.id)
                } else if it.kind == .file, FileManager.default.fileExists(atPath: self.resumeURL(it.id).path) {
                    self.mutate(it.id, now: true) { $0.state = .paused; $0.error = "اتوقف — دوس استكمال" }
                } else {
                    self.mutate(it.id, now: true) { $0.state = .failed; $0.error = "اتقطع — دوس إعادة المحاولة" }
                }
            }
        }
    }
}

// MARK: - URLSession delegates

extension DownloadManager: URLSessionDownloadDelegate, AVAssetDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : -1
        let s = sample(id, bytes: totalBytesWritten, total: total)
        mutate(id) { x in
            x.received = totalBytesWritten
            x.total = total
            x.progress = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
            if x.state == .failed { x.state = .downloading }
            if let sp = s.speed {
                x.speed = sp
                x.eta = s.eta
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription, let it = item(id) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            fail(id, "السيرفر رفض التحميل (HTTP \(http.statusCode)) — ممكن الرابط انتهى")
            return
        }
        let suggested = downloadTask.response?.suggestedFilename
        var name = it.nameHint ?? suggested ?? it.title
        if (name as NSString).pathExtension.isEmpty, let sug = suggested {
            let e = (sug as NSString).pathExtension
            if !e.isEmpty { name += "." + e }
        }
        let dest = Paths.unique(FileNames.sanitize(name), in: Paths.downloads)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            fail(id, "مقدرتش أحفظ الملف: \(error.localizedDescription)")
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        mutate(id, now: true) { x in
            x.fileName = dest.lastPathComponent
            x.title = dest.lastPathComponent
            x.state = .completed
            x.progress = 1
            x.finished = Date()
            x.speed = 0
            x.eta = 0
            x.error = nil
            if size > 0 { x.total = size; x.received = size }
        }
        try? FileManager.default.removeItem(at: resumeURL(id))
        notifyDone(dest.lastPathComponent)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        let sid = session.configuration.identifier ?? Self.fgSessionID
        speedSamples[id] = nil
        if let error { NSLog("NileDM: task %@ in %@ ended with %@", id, sid, error as NSError) }
        if wasCancelledByUs(task, in: sid) { return }

        if sid == Self.hlsSessionID {
            if let error {
                if let a = item(id)?.assetPath { try? FileManager.default.removeItem(at: Paths.fromHome(a)) }
                mutate(id) { $0.assetPath = nil }
                fail(id, friendly(error))
                return
            }
            mutate(id, now: true) { x in
                x.state = .processing
                x.progress = 1
                x.speed = 0
                x.eta = 0
            }
            exportMP4(id)
            return
        }

        guard let error else { return } // success is handled in didFinishDownloadingTo
        let ns = error as NSError
        // The iOS download service sometimes refuses a task outright (seen as "unknown error").
        // Retry once on an ordinary session instead of failing — it keeps going while the app is open.
        let refused: Set<Int> = [NSURLErrorUnknown, NSURLErrorBackgroundSessionWasDisconnected,
                                 NSURLErrorBackgroundSessionInUseByAnotherProcess,
                                 NSURLErrorBackgroundSessionRequiresSharedContainer]
        if sid == Self.fileSessionID, ns.domain == NSURLErrorDomain, refused.contains(ns.code),
           !fallbackTried.contains(id), let it = item(id), it.received == 0, it.state == .downloading {
            fallbackTried.insert(id)
            NSLog("NileDM: background service refused %@, retrying on ordinary session", id)
            DispatchQueue.main.async { self.startFileTask(it, ordinary: true) }
            return
        }
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeURL(id), options: .atomic)
        }
        if let reason = ns.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] as? Int,
           reason == NSURLErrorCancelledReasonUserForceQuitApplication {
            mutate(id, now: true) { x in
                x.state = .paused
                x.speed = 0
                x.error = "اتوقف لأن البرنامج اتقفل من قائمة البرامج — دوس استكمال"
            }
            return
        }
        fail(id, friendly(error))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        saveNow()
        lock.lock()
        let handler = backgroundHandlers.removeValue(forKey: identifier)
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }

    // HLS
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = assetDownloadTask.taskDescription else { return }
        mutate(id, now: true) { $0.assetPath = Paths.relativeToHome(location) }
    }

    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, didLoad timeRange: CMTimeRange,
                    totalTimeRangesLoaded loadedTimeRanges: [NSValue], timeRangeExpectedToLoad: CMTimeRange) {
        guard let id = assetDownloadTask.taskDescription else { return }
        let expected = timeRangeExpectedToLoad.duration.seconds
        var loaded = 0.0
        for v in loadedTimeRanges { loaded += v.timeRangeValue.duration.seconds }
        let pct = expected > 0 ? min(1, loaded / expected) : 0
        let bytes = assetDownloadTask.countOfBytesReceived
        let s = sample(id, bytes: bytes, total: -1)
        mutate(id) { x in
            x.progress = pct
            x.received = bytes
            if let sp = s.speed {
                x.speed = sp
                x.eta = (pct > 0.01 && sp > 0) ? (Double(bytes) / pct - Double(bytes)) / sp : 0
            }
        }
    }
}
