import Foundation

/// Hesap bilgisi (Xtream veya M3U adresi)
struct Account: Codable, Equatable {
    var kind: String          // "xtream" | "m3u"
    var server: String = ""   // http://host:port
    var user: String = ""
    var pass: String = ""
    var m3u: String = ""
}

enum Kind: String { case live, movie, series }

struct Category: Identifiable, Hashable {
    let id: String
    let name: String
}

struct Item: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String?
    let kind: Kind
    let url: URL?            // canlı / film için doğrudan adres
    let altURL: URL?         // oynatılamazsa denenecek HLS adresi
    let seriesId: String?
    let info: String?
}

struct Episode: Identifiable, Hashable {
    let id: String
    let title: String
    let season: Int
    let number: Int
    let url: URL?
    let altURL: URL?
}

enum ApiError: LocalizedError {
    case bad(String)
    var errorDescription: String? { if case .bad(let m) = self { return m }; return nil }
}

/// JSON'daki sayı/metin karışıklığına dayanıklı yardımcılar
private func str(_ v: Any?) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}

final class Api {
    let acc: Account
    private let session: URLSession

    init(_ acc: Account) {
        self.acc = acc
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpAdditionalHeaders = ["User-Agent": "VLC/3.0.20 LibVLC/3.0.20"]
        session = URLSession(configuration: cfg)
    }

    private var base: String {
        var s = acc.server.trimmingCharacters(in: .whitespaces)
        if !s.lowercased().hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s }

    private func call(_ action: String?, _ extra: [String: String] = [:]) async throws -> Any {
        var q = "username=\(enc(acc.user))&password=\(enc(acc.pass))"
        if let a = action { q += "&action=\(a)" }
        for (k, v) in extra { q += "&\(k)=\(enc(v))" }
        guard let url = URL(string: base + "/player_api.php?" + q) else { throw ApiError.bad("Sunucu adresi geçersiz") }
        let (data, resp) = try await session.data(from: url)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 { throw ApiError.bad("Sunucu hatası (HTTP \(h.statusCode))") }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Giriş doğrulama: hesap bilgisini döndürür
    func login() async throws -> String {
        if acc.kind == "m3u" { _ = try await m3uItems(); return "M3U listesi" }
        guard let j = try await call(nil) as? [String: Any], let ui = j["user_info"] as? [String: Any] else {
            throw ApiError.bad("Giriş başarısız: sunucu yanıtı anlaşılamadı")
        }
        if str(ui["auth"]) != "1" { throw ApiError.bad("Kullanıcı adı veya şifre hatalı") }
        let status = str(ui["status"])
        if !status.isEmpty && status.lowercased() != "active" { throw ApiError.bad("Hesap durumu: \(status)") }
        return str(ui["exp_date"])
    }

    func categories(_ kind: Kind) async throws -> [Category] {
        if acc.kind == "m3u" {
            let items = try await m3uItems()
            var seen = Set<String>(), out: [Category] = []
            for i in items { if let g = i.info, !seen.contains(g) { seen.insert(g); out.append(Category(id: g, name: g)) } }
            return out
        }
        let action = kind == .live ? "get_live_categories" : kind == .movie ? "get_vod_categories" : "get_series_categories"
        let arr = (try await call(action) as? [[String: Any]]) ?? []
        return arr.map { Category(id: str($0["category_id"]), name: str($0["category_name"])) }
    }

    func items(_ kind: Kind, cat: String) async throws -> [Item] {
        if acc.kind == "m3u" {
            return try await m3uItems().filter { $0.info == cat }
        }
        let u = enc(acc.user), p = enc(acc.pass)
        switch kind {
        case .live:
            let arr = (try await call("get_live_streams", ["category_id": cat]) as? [[String: Any]]) ?? []
            return arr.map { d in
                let id = str(d["stream_id"])
                return Item(id: id, name: str(d["name"]), icon: nilIfEmpty(str(d["stream_icon"])), kind: .live,
                            url: URL(string: "\(base)/live/\(u)/\(p)/\(id).m3u8"),
                            altURL: URL(string: "\(base)/live/\(u)/\(p)/\(id).ts"), seriesId: nil, info: nil)
            }
        case .movie:
            let arr = (try await call("get_vod_streams", ["category_id": cat]) as? [[String: Any]]) ?? []
            return arr.map { d in
                let id = str(d["stream_id"]); let ext = nilIfEmpty(str(d["container_extension"])) ?? "mp4"
                return Item(id: id, name: str(d["name"]), icon: nilIfEmpty(str(d["stream_icon"])), kind: .movie,
                            url: URL(string: "\(base)/movie/\(u)/\(p)/\(id).\(ext)"),
                            altURL: URL(string: "\(base)/movie/\(u)/\(p)/\(id).m3u8"), seriesId: nil, info: nil)
            }
        case .series:
            let arr = (try await call("get_series", ["category_id": cat]) as? [[String: Any]]) ?? []
            return arr.map { d in
                let id = str(d["series_id"])
                return Item(id: id, name: str(d["name"]), icon: nilIfEmpty(str(d["cover"])), kind: .series,
                            url: nil, altURL: nil, seriesId: id, info: nilIfEmpty(str(d["plot"])))
            }
        }
    }

    func episodes(seriesId: String) async throws -> [Episode] {
        let u = enc(acc.user), p = enc(acc.pass)
        guard let j = try await call("get_series_info", ["series_id": seriesId]) as? [String: Any],
              let eps = j["episodes"] as? [String: Any] else { return [] }
        var out: [Episode] = []
        for (seasonKey, v) in eps {
            guard let list = v as? [[String: Any]] else { continue }
            for e in list {
                let id = str(e["id"]); let ext = nilIfEmpty(str(e["container_extension"])) ?? "mp4"
                out.append(Episode(id: id, title: str(e["title"]), season: Int(seasonKey) ?? Int(str(e["season"])) ?? 0,
                                   number: Int(str(e["episode_num"])) ?? 0,
                                   url: URL(string: "\(base)/series/\(u)/\(p)/\(id).\(ext)"),
                                   altURL: URL(string: "\(base)/series/\(u)/\(p)/\(id).m3u8")))
            }
        }
        return out.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    // MARK: M3U
    private var m3uCache: [Item]?
    private func m3uItems() async throws -> [Item] {
        if let c = m3uCache { return c }
        guard let url = URL(string: acc.m3u.trimmingCharacters(in: .whitespaces)) else { throw ApiError.bad("M3U adresi geçersiz") }
        let (data, _) = try await session.data(from: url)
        let text = String(decoding: data, as: UTF8.self)
        var out: [Item] = []
        var name = "", logo: String? = nil, group = "Diğer"
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF") {
                name = line.components(separatedBy: ",").last ?? ""
                logo = attr(line, "tvg-logo")
                group = attr(line, "group-title") ?? "Diğer"
            } else if !line.isEmpty && !line.hasPrefix("#"), let u = URL(string: line) {
                out.append(Item(id: "m\(out.count)", name: name, icon: logo, kind: .live, url: u, altURL: nil, seriesId: nil, info: group))
                name = ""; logo = nil
            }
        }
        m3uCache = out
        return out
    }

    private func attr(_ line: String, _ key: String) -> String? {
        guard let r = line.range(of: key + "=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let e = rest.firstIndex(of: "\"") else { return nil }
        return nilIfEmpty(String(rest[..<e]))
    }

    private func nilIfEmpty(_ s: String) -> String? { s.isEmpty ? nil : s }
}
