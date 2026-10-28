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

import Foundation

public enum TxinCDN {

    /// (前缀, 替换为)
    public static let mirrors: [(from: String, to: String)] = [
        ("https://whk.srslpoh.cn/", "https://d22i72z1otaemb.cloudfront.net/"),
    ]

    public static let primaryHost = "whk.srslpoh.cn"
    public static let fallbackHost = "d22i72z1otaemb.cloudfront.net"

    /// 当前生效的替换规则（探测后可能清空）
    public static var activeMirrors: [(from: String, to: String)] = mirrors

    public static func rewrite(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        var out = url
        for m in activeMirrors where out.hasPrefix(m.from) {
            out = m.to + out.dropFirst(m.from.count)
        }
        if out.hasPrefix("//") { out = "https:" + out }
        if out.hasPrefix("/") { out = "https://tangxgw.com" + out }
        return out
    }

    /// 探测：返回 true 表示国内域名可用（没被劫持）
    public static func probeDomestic() async -> Bool {
        // 一个必定存在的静态资源（headico 编号 1 通常存在；失败就换 banner 兜底）
        let probePath = "/hc237/common_file/headico/common/122.bnc"
        guard let url = URL(string: "https://\(primaryHost)\(probePath)") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            // 拦截页特征：text/html，且长度恰好 11545
            if ctype.contains("text/html") { return false }
            if data.count == 11545 { return false }
            return true
        } catch {
            return false
        }
    }

    /// 启动时调用一次：国产域名被劫持就切到 CloudFront
    public static func autoSelectMirror() async {
        let domesticOK = await probeDomestic()
        if domesticOK {
            activeMirrors = []
        } else {
            activeMirrors = mirrors
        }
    }
}
