import Foundation

/// Minimal m3u8 reading: enough to tell a master playlist (with qualities) from a media playlist.
enum Playlist {
    static func isMaster(_ text: String) -> Bool {
        text.contains("#EXT-X-STREAM-INF")
    }

    static func isLive(_ text: String) -> Bool {
        !isMaster(text) && !text.contains("#EXT-X-ENDLIST") && !text.uppercased().contains("PLAYLIST-TYPE:VOD")
    }

    static func isDRM(_ text: String) -> Bool {
        let t = text.uppercased()
        return t.contains("METHOD=SAMPLE-AES") || t.contains("SKD://") || t.contains("COM.WIDEVINE") || t.contains("STREAMINGKEYDELIVERY")
    }

    /// KEY=VALUE,KEY="quoted, value"
    static func attributes(_ line: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var s = line[...]
        while !s.isEmpty {
            guard let eq = s.firstIndex(of: "=") else { break }
            let key = s[s.startIndex..<eq].trimmingCharacters(in: .whitespaces).uppercased()
            s = s[s.index(after: eq)...]
            var value = ""
            if s.first == "\"" {
                s = s.dropFirst()
                if let end = s.firstIndex(of: "\"") {
                    value = String(s[s.startIndex..<end])
                    s = s[s.index(after: end)...]
                } else {
                    value = String(s)
                    s = ""
                }
                if let comma = s.firstIndex(of: ",") { s = s[s.index(after: comma)...] } else { s = "" }
            } else if let comma = s.firstIndex(of: ",") {
                value = String(s[s.startIndex..<comma])
                s = s[s.index(after: comma)...]
            } else {
                value = String(s)
                s = ""
            }
            out[key] = value.trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Distinct qualities of a master playlist, best first.
    static func variants(_ text: String) -> [HLSVariant] {
        var list: [HLSVariant] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("#EXT-X-STREAM-INF:") else { continue }
            let a = attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))
            let bw = Double(a["BANDWIDTH"] ?? "") ?? 0
            var height = 0
            if let res = a["RESOLUTION"]?.lowercased().split(separator: "x"), res.count == 2 {
                height = Int(res[1]) ?? 0
            }
            let label = height > 0 ? "\(height)p" : "\(Int(bw / 1000)) kbps"
            list.append(HLSVariant(bandwidth: bw, height: height, label: label))
        }
        list.sort { $0.bandwidth > $1.bandwidth }
        var seen = Set<String>()
        return list.filter { seen.insert($0.label).inserted }
    }

    /// Bitrate to request for a quality preference ("best", "1080", "720"...). nil = highest.
    static func bitrate(for preference: String, in variants: [HLSVariant]) -> Double? {
        guard let limit = Int(preference), !variants.isEmpty else { return nil }
        if let v = variants.first(where: { $0.height > 0 && $0.height <= limit }) { return v.bandwidth }
        return variants.last?.bandwidth
    }

    static func fetch(_ url: URL, headers: [String: String]) async throws -> String {
        var req = URLRequest(url: url, timeoutInterval: 20)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            throw URLError(.badServerResponse)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Size of a direct file (HEAD request), or -1.
    static func size(of url: URL, headers: [String: String]) async -> Int64 {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "HEAD"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        guard let result = try? await URLSession.shared.data(for: req) else { return -1 }
        return result.1.expectedContentLength
    }
}
