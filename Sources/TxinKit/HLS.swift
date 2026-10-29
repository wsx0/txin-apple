//
//  HLS.swift
//  TxinKit
//
//  糖心的播放链路：/api/m3u8/p/<hash>.m3u8（明文 GET，无需鉴权）
//    -> EXT-X-KEY:METHOD=AES-128 (密钥地址带 sign，随播放列表一起下发)
//    -> 一堆 indexN.ts 分片
//  解密方式：AES-128-CBC，无 padding，整块处理，IV 取 EXT-X-KEY 里那个。
//

import Foundation
import AVFoundation

// MARK: - 播放列表

public struct HLSKey: Sendable {
    public let method: String
    public let uri: String
    public let iv: [UInt8]?
}

public struct HLSPlaylist: Sendable {
    public let url: String
    public let key: HLSKey?
    public let segments: [String]
    /// 每个分片的时长（对应 EXTINF），生成本地播放列表要用
    public let durations: [Double]
    public let targetDuration: Int?
    public let mediaSequence: Int

    /// 分片总时长（秒）
    public var totalDuration: Double { durations.reduce(0, +) }
}

public enum HLSError: Error, CustomStringConvertible {
    case badPlaylist(String)
    case emptySegments
    case keyFetchFailed
    case http(Int, String)

    public var description: String {
        switch self {
        case .badPlaylist(let m): return "播放列表异常: \(m)"
        case .emptySegments: return "播放列表里没有分片"
        case .keyFetchFailed: return "密钥获取失败"
        case .http(let c, let u): return "HTTP \(c) @ \(u)"
        }
    }
}

public enum HLSParser {

    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        guard text.contains("#EXTM3U") else {
            throw HLSError.badPlaylist("缺少 #EXTM3U")
        }
        var segments: [String] = []
        var durations: [Double] = []
        var pendingDuration: Double = 0
        var key: HLSKey?
        var target: Int?
        var mediaSeq = 0

        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                target = Int(line.dropFirst("#EXT-X-TARGETDURATION:".count))
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSeq = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXTINF:") {
                // #EXTINF:4.833333,  或带标题 #EXTINF:4.833333,标题
                let body = line.dropFirst("#EXTINF:".count)
                let numPart = body.split(separator: ",", maxSplits: 1).first ?? ""
                pendingDuration = Double(numPart.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attrs["METHOD"] ?? "NONE"
                let uri = attrs["URI"] ?? ""
                let ivHex = attrs["IV"]?.replacingOccurrences(of: "0x", with: "")
                    .replacingOccurrences(of: "0X", with: "")
                var iv: [UInt8]?
                if let ivHex, !ivHex.isEmpty, let bytes = try? TxinCrypto.hexToBytes(ivHex) {
                    iv = bytes
                }
                if method.uppercased() != "NONE" {
                    let absolute = URL(string: uri, relativeTo: baseURL)?.absoluteString ?? uri
                    key = HLSKey(method: method, uri: TxinCDN.rewrite(absolute) ?? absolute, iv: iv)
                }
            } else if !line.hasPrefix("#") {
                let absolute = URL(string: line, relativeTo: baseURL)?.absoluteString ?? line
                segments.append(TxinCDN.rewrite(absolute) ?? absolute)
                durations.append(pendingDuration)
                pendingDuration = 0
            }
        }

        guard !segments.isEmpty else { throw HLSError.emptySegments }
        return HLSPlaylist(url: baseURL.absoluteString,
                           key: key,
                           segments: segments,
                           durations: durations,
                           targetDuration: target,
                           mediaSequence: mediaSeq)
    }

    static func parseAttributes(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        // URI="..." 里有逗号的情况要跳过引号内
        var current = ""
        var inQuotes = false
        var parts: [String] = []
        for ch in s {
            if ch == "\"" {
                inQuotes.toggle()
                current.append(ch)
            } else if ch == "," && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        for p in parts {
            guard let eq = p.firstIndex(of: "=") else { continue }
            let k = String(p[p.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(p[p.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\""), v.hasSuffix("\""), v.count >= 2 {
                v = String(v.dropFirst().dropLast())
            }
            out[k] = v
        }
        return out
    }
}

// MARK: - 下载器

public struct HLSDownloadProgress: Sendable {
    public let done: Int
    public let total: Int
    public let bytes: Int64
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

public actor HLSDownloader {

    private let session: URLSession
    private let concurrency: Int

    public init(concurrency: Int = 6) {
        self.concurrency = max(1, concurrency)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    /// 取播放列表
    public func fetchPlaylist(m3u8 urlString: String, referer: String) async throws -> HLSPlaylist {
        guard let url = URL(string: urlString) else {
            throw HLSError.badPlaylist("URL 非法: \(urlString)")
        }
        var req = URLRequest(url: url)
        req.setValue(TxinClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HLSError.http(0, urlString) }
        guard http.statusCode == 200 else { throw HLSError.http(http.statusCode, urlString) }
        let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if ctype.contains("text/html") {
            throw HLSError.badPlaylist("拿到的是 HTML，可能被劫持到拦截页")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw HLSError.badPlaylist("非 UTF-8")
        }
        return try HLSParser.parse(text, baseURL: url)
    }

    /// 整条链下载到本地 TS，返回文件 URL
    @discardableResult
    public func download(_ playlist: HLSPlaylist,
                         to directory: URL,
                         referer: String,
                         onProgress: (@Sendable (HLSDownloadProgress) -> Void)? = nil,
                         onState: (@Sendable (String) -> Void)? = nil) async throws -> URL {

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // 1) 密钥
        var aesKey: [UInt8]?
        if let k = playlist.key, k.method.uppercased() == "AES-128" {
            onState?("获取解密密钥…")
            guard let ku = URL(string: k.uri) else { throw HLSError.keyFetchFailed }
            var req = URLRequest(url: ku)
            req.setValue(TxinClient.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue(referer, forHTTPHeaderField: "Referer")
            let (kd, kr) = try await session.data(for: req)
            guard let kh = kr as? HTTPURLResponse, kh.statusCode == 200, kd.count >= 16 else {
                throw HLSError.keyFetchFailed
            }
            if (kh.value(forHTTPHeaderField: "Content-Type") ?? "").contains("html") {
                throw HLSError.keyFetchFailed
            }
            aesKey = [UInt8](kd.prefix(16))
            try kd.write(to: directory.appendingPathComponent("enc.key"))
        }

        let total = playlist.segments.count
        let iv = playlist.key?.iv ?? [UInt8](repeating: 0, count: 16)

        // 2) 分片（有界并发，保持顺序写盘）
        let dir = directory
        var buffers = [[UInt8]?](repeating: nil, count: total)
        var bytes: Int64 = 0
        var done = 0

        try await withThrowingTaskGroup(of: (Int, [UInt8]).self) { group in
            var next = 0
            let batch = min(concurrency, total)

            while next < batch {
                let idx = next
                let seg = playlist.segments[idx]
                group.addTask { [session] in
                    let data = try await HLSDownloader.fetchSegment(session, seg, referer)
                    return (idx, data)
                }
                next += 1
            }

            for try await (idx, data) in group {
                let plain: [UInt8]
                if let aesKey {
                    plain = (try? TxinCrypto.aesCBCDecryptNoPadding(key: aesKey, iv: iv, cipher: data)) ?? data
                } else {
                    plain = data
                }
                buffers[idx] = plain
                bytes += Int64(plain.count)
                done += 1
                onProgress?(HLSDownloadProgress(done: done, total: total, bytes: bytes))

                if next < total {
                    let idx2 = next
                    let seg2 = playlist.segments[idx2]
                    group.addTask { [session] in
                        let data = try await HLSDownloader.fetchSegment(session, seg2, referer)
                        return (idx2, data)
                    }
                    next += 1
                }
            }
        }

        // 3) 把解好密的分片逐个落盘（保留，后面要用）
        onState?("写入分片…")
        for (i, buf) in buffers.enumerated() {
            guard let buf else { continue }
            let segURL = dir.appendingPathComponent(String(format: "seg_%04d.ts", i))
            try Data(buf).write(to: segURL)
        }

        // 4) 生成本地 HLS 播放列表 —— 这一步是关键。
        //    AVPlayer 对「裸 .ts 文件」支持不稳（常见症状：只播开头几秒就停），
        //    但对「本地 m3u8 + 同目录分片」是原生支持的，等同于流播体验。
        onState?("生成本地播放列表…")
        let targetDur = playlist.targetDuration ?? 5
        var m3u8 = "#EXTM3U\n"
        m3u8 += "#EXT-X-VERSION:3\n"
        m3u8 += "#EXT-X-TARGETDURATION:\(targetDur)\n"
        m3u8 += "#EXT-X-MEDIA-SEQUENCE:0\n"
        m3u8 += "#EXT-X-PLAYLIST-TYPE:VOD\n"
        for (i, d) in playlist.durations.enumerated() where i < buffers.count {
            // 时长缺失时给个保守值，别写 0（0 会让播放器直接跳过）
            let dur = d > 0 ? d : Double(targetDur)
            m3u8 += "#EXTINF:" + String(format: "%.6f", dur) + ",\n"
            m3u8 += String(format: "seg_%04d.ts\n", i)
        }
        m3u8 += "#EXT-X-ENDLIST\n"
        try m3u8.write(to: dir.appendingPathComponent("index.m3u8"),
                       atomically: true, encoding: .utf8)

        // 5) 再合并一份整片，给「导出 / 分享」用
        onState?("合并分片…")
        let merged = dir.appendingPathComponent("merged.ts")
        FileManager.default.createFile(atPath: merged.path, contents: nil)
        let handle = try FileHandle(forWritingTo: merged)
        defer { try? handle.close() }
        for buf in buffers {
            if let buf { try handle.write(contentsOf: Data(buf)) }
        }

        // 6) 重新封装成 mp4。
        //    为什么必须做：分片拼接出来的 .ts 里有多套 PAT/PMT program 声明，
        //    AVPlayer 遇到这种文件常常只认第一个 program —— 也就是开头几秒。
        //    先建 composition 只取首路，再 passthrough 封装；失败或截断就重编码。
        onState?("重新封装为 mp4…")
        let mp4 = dir.appendingPathComponent("video.mp4")
        do {
            try await remuxToMp4(merged, to: mp4)
            try? "ok".write(to: dir.appendingPathComponent("remux-error.txt"),
                            atomically: true, encoding: .utf8)
            return mp4
        } catch {
            // 失败原因落盘，App 的诊断面板会显示它
            let msg = "\(error)"
            try? msg.write(to: dir.appendingPathComponent("remux-error.txt"),
                           atomically: true, encoding: .utf8)
            onState?("remux 失败，退回 ts")
            return merged
        }
    }

    // MARK: - remux

    /// 把 .ts 无损重新封装成 .mp4。
    ///
    /// 为什么不能直接拿整片 export：分片拼接出来的 TS 里有**多套 PAT/PMT program 声明**
    /// （每个分片自带一份），`AVAssetExportSession` 直接吃这种 asset 时，
    /// 往往"成功"导出但只有第一个 program —— 也就是开头几秒。
    /// 所以先建一个 AVMutableComposition，只取第一路视频和第一路音频，
    /// 等价于 ffmpeg 的 `-map 0:v:0 -map 0:a:0`。
    public func remuxToMp4(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let fullRange = CMTimeRange(start: .zero, duration: try await asset.load(.duration))

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let firstVideo = videoTracks.first else {
            throw HLSError.badPlaylist("源文件里没有视频轨")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(withMediaType: .video,
                                                       preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw HLSError.badPlaylist("无法创建视频轨")
        }
        try vTrack.insertTimeRange(fullRange, of: firstVideo, at: .zero)

        if let a = audioTracks.first,
           let aTrack = composition.addMutableTrack(withMediaType: .audio,
                                                    preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? aTrack.insertTimeRange(fullRange, of: a, at: .zero)
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        // 先试 passthrough（快、不重编码）；失败或时长明显不对就重编码
        let presets = [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        var lastError: Error?

        for preset in presets {
            guard let export = AVAssetExportSession(asset: composition, presetName: preset) else {
                continue
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try? FileManager.default.removeItem(at: destination)
            }
            export.outputURL = destination
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true
            export.timeRange = fullRange

            do {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    export.exportAsynchronously {
                        switch export.status {
                        case .completed: cont.resume()
                        case .cancelled: cont.resume(throwing: HLSError.badPlaylist("remux 被取消"))
                        default: cont.resume(throwing: export.error ?? HLSError.badPlaylist("remux 失败"))
                        }
                    }
                }
                // 关键校验：导出结果的时长必须接近源，否则就是被截断了
                let outAsset = AVURLAsset(url: destination)
                let outDur = try await outAsset.load(.duration).seconds
                let srcDur = fullRange.duration.seconds
                if srcDur > 0, outDur >= srcDur * 0.95 {
                    return
                }
                lastError = HLSError.badPlaylist(
                    "remux 结果只有 \(String(format: "%.1f", outDur))s / 源 \(String(format: "%.1f", srcDur))s，判定截断")
            } catch {
                lastError = error
            }
        }
        throw lastError ?? HLSError.badPlaylist("remux 全部预设失败")
    }

    /// 取单个分片，带重试。
    /// CDN 在手机上经常零星超时/断连，一次失败就放弃整个下载太脆了。
    static func fetchSegment(_ session: URLSession, _ urlString: String, _ referer: String) async throws -> [UInt8] {
        guard let url = URL(string: urlString) else { throw HLSError.http(0, urlString) }

        var lastError: Error?
        for attempt in 0..<4 {
            if attempt > 0 {
                // 退避：0.6s / 1.2s / 2.4s
                let delay = UInt64(600_000_000) << UInt64(attempt - 1)
                try? await Task.sleep(nanoseconds: delay)
            }
            do {
                var req = URLRequest(url: url)
                req.timeoutInterval = 30
                req.setValue(TxinClient.userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue(referer, forHTTPHeaderField: "Referer")
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw HLSError.http(0, urlString)
                }
                guard http.statusCode == 200 else {
                    throw HLSError.http(http.statusCode, urlString)
                }
                let ctype = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                if ctype.contains("html") {
                    throw HLSError.http(200, "被拦截: \(urlString)")
                }
                if data.isEmpty {
                    throw HLSError.http(0, "空分片: \(urlString)")
                }
                return [UInt8](data)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError ?? HLSError.http(0, urlString)
    }
}
