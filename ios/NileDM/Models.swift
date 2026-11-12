import Foundation

enum DLKind: String, Codable {
    case file   // any normal file, downloaded with a background URLSession
    case hls    // m3u8 stream, downloaded with AVAssetDownloadURLSession, then turned into MP4
}

enum DLState: String, Codable {
    case downloading, paused, completed, failed, processing
}

struct DownloadItem: Identifiable, Codable, Equatable {
    var id: String
    var kind: DLKind
    var url: String
    var pageURL: String?
    var title: String              // what the user sees (final file name once done)
    var nameHint: String?          // wanted file name (with extension) if we know it
    var fileName: String?          // final file in Paths.downloads
    var assetPath: String?         // HLS: .movpkg path relative to home
    var state: DLState
    var received: Int64 = 0
    var total: Int64 = -1
    var progress: Double = 0
    var error: String?
    var created: Date
    var finished: Date?
    var headers: [String: String] = [:]
    var bitrate: Double?           // HLS: chosen quality (nil = best)
    var speed: Double = 0          // runtime only
    var eta: Double = 0            // runtime only

    enum CodingKeys: String, CodingKey {
        case id, kind, url, pageURL, title, nameHint, fileName, assetPath, state, received, total
        case progress, error, created, finished, headers, bitrate
    }

    var isActive: Bool { state == .downloading || state == .processing }

    /// The playable / shareable local file, if any.
    var localURL: URL? {
        if let f = fileName { return Paths.downloads.appendingPathComponent(f) }
        if let a = assetPath { return Paths.fromHome(a) }
        return nil
    }

    var isVideo: Bool {
        if kind == .hls { return true }
        let e = ((fileName ?? title) as NSString).pathExtension.lowercased()
        return FileNames.videoExts.contains(e)
    }

    var isAudio: Bool {
        let e = ((fileName ?? title) as NSString).pathExtension.lowercased()
        return FileNames.audioExts.contains(e)
    }
}

/// A video / audio / stream found on the current web page.
struct MediaItem: Identifiable, Equatable {
    enum Kind: String { case hls, video, audio, dash }
    var url: URL
    var kind: Kind
    var pageURL: URL?
    var title: String
    var isMaster = false
    var variants: [HLSVariant] = []
    var hidden = false
    var size: Int64 = -1
    var found = Date()

    var id: String { url.absoluteString }

    var badge: String {
        switch kind {
        case .hls: return "HLS"
        case .dash: return "DASH"
        case .audio: return "صوت"
        case .video:
            let e = url.pathExtension.uppercased()
            return e.isEmpty ? "فيديو" : String(e.prefix(4))
        }
    }

    var displayName: String {
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return last.isEmpty ? (url.host ?? url.absoluteString) : last
    }
}

struct HLSVariant: Equatable, Hashable {
    var bandwidth: Double
    var height: Int
    var label: String
}
