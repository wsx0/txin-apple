//
//  TxinResourceLoader.swift
//  Txin （iOS / macOS 通用）
//
//  为什么需要它：
//    `AVURLAssetHTTPHeaderFieldsKey` 只对**主请求**生效。HLS 的子请求
//    （分片 .ts、#EXT-X-KEY 指向的 key）是 AVFoundation 自己发的，
//    不会带我们设的 Referer/User-Agent —— CDN 直接 403，播放器播完
//    第一个能用的分片就没有后续了，表现为「只播几秒就停」。
//
//    用 AVAssetResourceLoaderDelegate 接管自定义 scheme 下的**所有**请求，
//    自己发 HTTP（带齐 header、带重试），再把数据交回给 AVFoundation。
//    这样 m3u8、key、每个 ts 分片都走同一条可控通道。
//

import Foundation
import AVFoundation

public final class TxinResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    public static let scheme = "txin"
    public static let host = "media.local"

    private let session: URLSession
    private let referer: String
    private let userAgent: String

    /// 内存里的小缓存，避免同一个分片被重复拉两次
    private var cache: [String: Data] = [:]
    private let cacheLock = NSLock()

    public init(referer: String, userAgent: String = TxinClient.userAgent) {
        self.referer = referer
        self.userAgent = userAgent
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 120
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpMaximumConnectionsPerHost = 6
        self.session = URLSession(configuration: cfg)
        super.init()
    }

    // MARK: - scheme 转换

    /// https://tangxgw.com/api/m3u8/p/xxx.m3u8
    ///   -> txin://media.local/api/m3u8/p/xxx.m3u8
    public static func encode(_ url: URL) -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = scheme
        c?.host = host
        return c?.url
    }

    /// txin://media.local/api/... -> https://tangxgw.com/api/...
    private func decode(_ url: URL) -> URL? {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.scheme = "https"
        c?.host = URL(string: referer)?.host ?? "tangxgw.com"
        return c?.url
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let reqURL = request.request.url, let target = decode(reqURL) else { return false }
        let key = target.absoluteString

        // 命中缓存
        cacheLock.lock()
        let hit = cache[key]
        cacheLock.unlock()
        if let hit {
            fulfill(request, data: hit)
            return true
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.fetch(target)
                self.cacheLock.lock()
                if self.cache.count < 64 { self.cache[key] = data }
                self.cacheLock.unlock()
                self.fulfill(request, data: data)
            } catch {
                request.finishLoading(with: error)
            }
        }
        return true
    }

    // MARK: - 实际抓取

    private func fetch(_ target: URL, attempts: Int = 4) async throws -> Data {
        var lastError: Error?
        for i in 0..<attempts {
            if i > 0 {
                try? await Task.sleep(nanoseconds: UInt64(400_000_000) << UInt64(i - 1))
            }
            do {
                var req = URLRequest(url: target)
                req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue(referer, forHTTPHeaderField: "Referer")
                req.setValue(referer, forHTTPHeaderField: "Origin")
                req.setValue("*/*", forHTTPHeaderField: "Accept")
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw NSError(domain: "txin", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "无响应"])
                }
                guard http.statusCode == 200 else {
                    throw NSError(domain: "txin", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) \(target.lastPathComponent)"])
                }
                if data.isEmpty {
                    throw NSError(domain: "txin", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "空数据"])
                }
                return data
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? NSError(domain: "txin", code: -3,
                                   userInfo: [NSLocalizedDescriptionKey: "重试耗尽"])
    }

    // MARK: - 回填

    private func fulfill(_ request: AVAssetResourceLoadingRequest, data: Data) {
        if let info = request.contentInformationRequest {
            info.isByteRangeAccessSupported = true
            info.contentLength = Int64(data.count)
            info.contentType = Self.mimeType(for: request.request.url?.pathExtension ?? "")
        }
        if let dr = request.dataRequest {
            let start = Int(dr.requestedOffset)
            let len = dr.requestedLength > 0 ? dr.requestedLength : data.count
            let end = min(data.count, start + len)
            if start < end {
                dr.respond(with: data.subdata(in: start..<end))
            }
        }
        request.finishLoading()
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts":   return "video/mp2t"
        case "mp4":  return "video/mp4"
        case "key":  return "application/octet-stream"
        default:     return "application/octet-stream"
        }
    }

    public func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheLock.unlock()
    }
}
