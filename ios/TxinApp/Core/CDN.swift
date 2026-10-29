//
//  CDN.swift
//  TxinKit
//
//  站点媒体走两套 CDN：
//    国内  https://whk.srslpoh.cn/...
//    海外  https://d22i72z1otaemb.cloudfront.net/...   （同路径镜像）
//
//  实测：国内那套在部分网络被 DNS 劫持到 183.192.65.101（证书 CN=上海市公安局），
//  所有请求返回同一个 11545 字节 HTML 拦截页。所以默认改写走 CloudFront，
//  并在启动时探测一次，选真正能出数据的那个。
//
//  并发说明：原来的 `static var activeMirrors` 是可变的全局共享状态，
//  Swift 6 的严格并发检查会直接判它不合法。这里收进一个带锁的
//  @unchecked Sendable 单例里，读写都上锁。
//

import Foundation

public enum TxinCDN {

    /// (前缀, 替换为)
    public static let mirrors: [(from: String, to: String)] = [
        ("https://whk.srslpoh.cn/", "https://d22i72z1otaemb.cloudfront.net/"),
    ]

    public static let primaryHost = "whk.srslpoh.cn"
    public static let fallbackHost = "d22i72z1otaemb.cloudfront.net"

    // MARK: - 可变状态（带锁）

    final class State: @unchecked Sendable {
        static let shared = State()
        private let lock = NSLock()
        private var value: [(from: String, to: String)] = TxinCDN.mirrors

        var mirrors: [(from: String, to: String)] {
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

    /// 当前生效的替换规则（探测后可能清空）
    public static var activeMirrors: [(from: String, to: String)] {
        get { State.shared.mirrors }
        set { State.shared.mirrors = newValue }
    }

    // MARK: - 改写

    public static func rewrite(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        var out = url
        for m in State.shared.mirrors where out.hasPrefix(m.from) {
            out = m.to + out.dropFirst(m.from.count)
        }
        if out.hasPrefix("//") { out = "https:" + out }
        if out.hasPrefix("/") { out = "https://tangxgw.com" + out }
        return out
    }

    /// 改写整份 m3u8 里的所有 URL。
    ///
    /// 流播时播放器会直接请求 m3u8 里写的地址，根本不会经过 `rewrite(_:)` ——
    /// 所以国内 DNS 把 whk.srslpoh.cn 劫持到 183.192.65.101 之后，
    /// 播放器拿到的是那个 11545 字节的 HTML 拦截页（HTTP 还是 200），
    /// 当成 TS 去解码必然失败，表现就是「播几秒就停」。
    ///
    /// m3u8 里要改的有两处：`#EXT-X-KEY` 的 URI（key 也在 whk 上）
    /// 和每个分片行。直接按域名做全文字符串替换最稳，相对路径不用动。
    public static func rewritePlaylist(_ text: String) -> String {
        var out = text
        for m in State.shared.mirrors {
            out = out.replacingOccurrences(of: m.from, with: m.to)
            // 也覆盖不带 scheme 的写法
            let hostFrom = m.from.replacingOccurrences(of: "https://", with: "")
            let hostTo = m.to.replacingOccurrences(of: "https://", with: "")
            if !hostFrom.isEmpty {
                out = out.replacingOccurrences(of: hostFrom, with: hostTo)
            }
        }
        return out
    }

    // MARK: - 探测

    /// 返回 true 表示国内域名可用（没被劫持）
    public static func probeDomestic() async -> Bool {
        let probePath = "/hc237/common_file/headico/common/122.bnc"
        guard let url = URL(string: "https://\(primaryHost)\(probePath)") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if ctype.contains("text/html") { return false }
            if data.count == 11545 { return false }
            return true
        } catch {
            return false
        }
    }

    /// 启动时调用一次：国内域名被劫持就切到 CloudFront
    public static func autoSelectMirror() async {
        let domesticOK = await probeDomestic()
        State.shared.mirrors = domesticOK ? [] : mirrors
    }
}
