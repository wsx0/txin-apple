//
//  TxinAPI.swift
//  TxinKit
//
//  协议全貌（逆向自 /_nuxt/DeE7C1J3.js class wl）：
//
//    secret    = "x3t8rvtaescfe38s"
//    requestId = uuid v4，每次请求新生成
//    key       = HMAC-SHA256(message = hex(requestId 去横线), HMAC-key = secret)  -> 32B -> AES-256
//    body      = base64( IV(16) || AES-256-CBC( gzip(JSON({data,token,deviceId})), key, IV, PKCS7 ) )
//    headers   = content-type: text/plain, time(11位), version, deviceType: web, requestId, language
//    响应       = 同一个 requestId 派生同一把 key；解出的字节先 gunzip 再 JSON
//
//  会话 cookie（AES-128-ECB / key = "4ntmubrorxzqalmq"）：
//    c_tt -> {"user_id","token","is_vip",...}
//    c_dd -> deviceId 明文
//

import Foundation

public enum TxinAPIError: Error, CustomStringConvertible {
    case http(Int, String)
    case emptyBody
    case decode(String)
    case business(String)
    case noSession

    public var description: String {
        switch self {
        case .http(let code, let path):
            if code == -1009 || code < 0 {
                return "网络连不上（\(path)）。域名 DNS 可能被污染，或需要代理。"
            }
            return "HTTP \(code) @ \(path)"
        case .emptyBody: return "响应体为空"
        case .decode(let m): return "解码失败: \(m)"
        case .business(let m): return m
        case .noSession: return "尚未建立会话，先调用 bootstrap()"
        }
    }
}

// MARK: - 当前生效的接入点

/// bootstrap 探测成功后把选中的主机写进这里，其它地方（拼 m3u8 绝对地址、Referer）
/// 直接读它即可，不用把 async 传播到 UI 层。
public enum TxinEndpoint {

    final class State: @unchecked Sendable {
        static let shared = State()
        private let lock = NSLock()
        private var value = TxinClient.defaultHost

        var host: String {
            get {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
            set {
                lock.lock()
                defer { lock.unlock() }
                value = newValue
            }
        }
    }

    /// 形如 https://tangxgw.com
    public static var current: String {
        get { State.shared.host }
        set { State.shared.host = newValue }
    }

    /// 形如 https://tangxgw.com/
    public static var base: String { current + "/" }
}

public actor TxinClient {

    // 协议常量
    public static let defaultHost = "https://tangxgw.com"
    public static let apiSecret = "x3t8rvtaescfe38s"
    public static let cookieKey = "4ntmubrorxzqalmq"

    /// 候选接入点。
    /// 第一个是主域名，国内直连时 DNS 常被污染（解析出 0 个 IP，NSURLError -1009）。
    /// 第二个是 CloudFront 的默认域名 —— 实测 `GET /` 直接返回 200 + 完整首页，
    /// 不需要 Host 头覆盖；而 cloudfront.net 不在污染名单里，所以它能绕过 DNS 问题。
    /// App 启动时逐个探测，选第一个真正能拿到页面的。
    public static let candidateHosts: [String] = [
        "https://tangxgw.com",
        "https://d135a0g6n89vl1.cloudfront.net",
        "https://tangxinweb.com",
        "https://txinweb1.com",
        "https://tangxin.net",
    ]

    public private(set) var host: String
    private let session: URLSession
    private var cookies: [String: String] = [:]

    public private(set) var profile: TxinProfile?
    public private(set) var deviceId: String = ""
    public private(set) var systemInfo: TxinSystemInfo?

    /// host 传空表示自动探测
    public init(host: String = "") {
        self.host = host
        // 注意：不要用 .ephemeral + httpShouldSetCookies=false。
        // 那种配置下 macOS 的 URLSession 根本不会把 Set-Cookie 放进 allHeaderFields，
        // c_tt 就拿不到，只能靠 c_dd 兜底出 deviceId（表现为 user_id/token 全是 "-"）。
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - 接入点探测

    /// 逐个试候选主机，返回第一个能拿到正常首页的（而不是拦截页/超时）
    public static func probeHost() async -> String? {
        for h in candidateHosts {
            guard let url = URL(string: h + "/") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 8
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { continue }
                let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                // 首页至少几十 KB；拦截页通常是个很短的 HTML
                if ctype.contains("text/html") && data.count > 10_000 {
                    return h
                }
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - 会话建立

    /// 拉一次首页拿 Set-Cookie，解出匿名账号
    public func bootstrap() async throws {
        // 没指定 host 就先探测
        if host.isEmpty {
            guard let h = await TxinClient.probeHost() else {
                throw TxinAPIError.business(
                    "所有候选域名都连不上。国内网络常见的两个原因：\n"
                    + "① 域名 DNS 被污染（解析出 0 个 IP）\n"
                    + "② 需要代理才能访问\n"
                    + "已尝试：\(TxinClient.candidateHosts.joined(separator: "、"))")
            }
            host = h
            TxinEndpoint.current = h
        }

        guard let url = URL(string: host + "/") else { throw TxinAPIError.http(0, "bad host") }
        var req = URLRequest(url: url)
        req.setValue(TxinClient.userAgent, forHTTPHeaderField: "User-Agent")

        let (_, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TxinAPIError.http(0, "/") }
        guard http.statusCode == 200 else { throw TxinAPIError.http(http.statusCode, "/") }

        // 首选 HTTPCookieStorage（URLSession 已经把 Set-Cookie 存进去了）
        var jar: [String: String] = [:]
        for c in (HTTPCookieStorage.shared.cookies(for: url) ?? []) where c.name.hasPrefix("c_") {
            jar[c.name] = c.value
        }
        // 兜底：直接扫响应头
        if jar["c_tt"] == nil {
            for (k, v) in TxinClient.parseSetCookie(http) {
                if jar[k] == nil { jar[k] = v }
            }
        }
        cookies = jar
        guard !cookies.isEmpty else { throw TxinAPIError.noSession }

        if let tt = cookies["c_tt"], let plain = try? decryptCookie(tt) {
            if let data = plain.data(using: .utf8),
               let p = try? JSONDecoder().decode(TxinProfile.self, from: data) {
                profile = p
            }
        }
        if let dd = cookies["c_dd"], let plain = try? decryptCookie(dd) {
            deviceId = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if deviceId.isEmpty {
            deviceId = TxinCrypto.uuidv4()
        }
    }

    public var token: String {
        guard let p = profile, let t = p.token, let u = p.user_id else { return "" }
        return "\(t)_\(u)"
    }

    // MARK: - 通用调用

    /// 调任意接口，返回解密后的 JSON Data
    public func callRaw(_ path: String, payload: Any? = nil, method: String = "POST") async throws -> Data {
        let requestId = TxinCrypto.uuidv4()
        let key = try TxinCrypto.deriveKey(requestId: requestId, secret: TxinClient.apiSecret)
        let iv = TxinCrypto.randomBytes(16)

        let envelope: [String: Any] = [
            "data": payload ?? [String: Any](),
            "token": token,
            "deviceId": deviceId,
        ]
        let json = try JSONSerialization.data(withJSONObject: envelope, options: [])
        let gz = try TxinGzip.gzip([UInt8](json))
        let cipher = try TxinCrypto.aesCBCEncrypt(key: key, iv: iv, plain: gz)
        let bodyString = Data(iv + cipher).base64EncodedString()

        guard let url = URL(string: host + "/api" + path) else {
            throw TxinAPIError.http(0, path)
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = Data(bodyString.utf8)
        req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        req.setValue(TxinCrypto.shortTimestamp(), forHTTPHeaderField: "time")
        req.setValue("1.0.0", forHTTPHeaderField: "version")
        req.setValue("web", forHTTPHeaderField: "deviceType")
        req.setValue(requestId, forHTTPHeaderField: "requestId")
        req.setValue("zh-cn", forHTTPHeaderField: "language")
        req.setValue(TxinClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(host + "/", forHTTPHeaderField: "Referer")
        let cookieHeader = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        if !cookieHeader.isEmpty {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw TxinAPIError.http(0, path) }
        guard http.statusCode == 200 else {
            throw TxinAPIError.http(http.statusCode, path)
        }
        guard !data.isEmpty else { throw TxinAPIError.emptyBody }

        return try TxinClient.decryptResponse(data, key: key)
    }

    /// 泛型版本
    public func call<T: Decodable>(_ path: String, payload: Any? = nil,
                                   as type: T.Type = T.self) async throws -> T {
        let data = try await callRaw(path, payload: payload)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "<binary>"
            throw TxinAPIError.decode("\(T.self): \(error.localizedDescription) preview=\(preview)")
        }
    }

    // MARK: - 业务快捷方法

    public func systemInfo() async throws -> TxinEnvelope<TxinSystemInfo> {
        let r: TxinEnvelope<TxinSystemInfo> = try await call("/system/info",
                                                             payload: ["channel_code": NSNull(),
                                                                       "share_code": NSNull()])
        if let d = r.data {
            systemInfo = d
            // 图片解密要用它，拿到就立刻写进全局
            if let k = d.img_key, !k.isEmpty {
                TxinImage.imgKey = k
            }
        }
        return r
    }

    public func home() async throws -> TxinEnvelope<TxinHome> {
        return try await call("/system/home", payload: [String: Any]())
    }

    public func movieHome(catId: String = "1", page: Int = 1) async throws -> TxinEnvelope<TxinMovieList> {
        return try await call("/movie/home", payload: ["cat_id": catId, "page": page])
    }

    public func movieDetail(id: String) async throws -> TxinEnvelope<TxinMovieDetail> {
        return try await call("/movie/detail", payload: ["id": id])
    }

    public func artistHome() async throws -> TxinEnvelope<TxinArtistHome> {
        return try await call("/artist/home", payload: [String: Any]())
    }

    public func tags(keyword: String = "") async throws -> TxinEnvelope<TxinTagPage> {
        return try await call("/search/tag", payload: ["keyword": keyword])
    }

    // MARK: - 内部工具

    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func parseSetCookie(_ resp: HTTPURLResponse) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in resp.allHeaderFields {
            guard String(describing: k).lowercased() == "set-cookie" else { continue }
            let text: String
            if let arr = v as? [String] {
                text = arr.joined(separator: ",")
            } else {
                text = String(describing: v)
            }
            // 只抓 c_ 前缀的两枚：c_tt / c_dd
            let pattern = try? NSRegularExpression(pattern: #"(c_[A-Za-z0-9_]+)=([^;,]*)"#)
            let ns = text as NSString
            pattern?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges == 3 else { return }
                let name = ns.substring(with: m.range(at: 1))
                let value = ns.substring(with: m.range(at: 2))
                out[name] = value
            }
        }
        return out
    }

    func decryptCookie(_ value: String) throws -> String {
        let key = [UInt8](TxinClient.cookieKey.utf8)
        let raw = try TxinCrypto.base64Decode(value)
        let plain = try TxinCrypto.aesECBDecrypt(key: key, cipher: raw)
        guard let s = String(bytes: plain, encoding: .utf8) else {
            throw TxinAPIError.decode("cookie 非 UTF-8")
        }
        return s
    }

    /// 响应可能是「裸二进制」也可能被某些网关转成 base64 文本，两种都试。
    static func decryptResponse(_ data: Data, key: [UInt8]) throws -> Data {
        var raw = [UInt8](data)

        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBase64ish = trimmed.range(of: #"^[A-Za-z0-9+/=\s]+$"#,
                                            options: .regularExpression) != nil
            if isBase64ish, trimmed.count > 32, trimmed.count % 4 == 0,
               let decoded = try? TxinCrypto.base64Decode(trimmed) {
                raw = decoded
            }
        }

        guard raw.count > 32 else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw TxinAPIError.decode("响应过短(\(raw.count)B) preview=\(preview)")
        }

        let iv = Array(raw[0..<16])
        let cipher = Array(raw[16...])
        let gz = try TxinCrypto.aesCBCDecrypt(key: key, iv: iv, cipher: cipher)

        // 正常是 gzip；服务端偶尔直接给明文（例如 upload 接口），两种都接
        if let plain = try? TxinGzip.gunzip(gz), !plain.isEmpty {
            return Data(plain)
        }
        return Data(gz)
    }
}
