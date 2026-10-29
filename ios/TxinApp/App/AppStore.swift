//
//  AppStore.swift
//  Txin （iOS）
//

import Foundation
import SwiftUI
import UIKit
import AVFoundation

// MARK: - 下载任务（值类型，配合 @Published 数组）

struct DownloadJob: Identifiable, Equatable {
    enum Phase: String {
        case queued      = "排队中"
        case playlist    = "取播放列表"
        case downloading = "下载中"
        case merging     = "合并中"
        case done        = "已完成"
        case failed      = "失败"
    }

    let id: String
    let title: String
    var phase: Phase = .queued
    var done: Int = 0
    var total: Int = 0
    var bytes: Int64 = 0
    var filePath: String?
    var note: String = ""

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var sizeText: String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
    var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }
}

// MARK: - 主状态

@MainActor
final class AppStore: ObservableObject {

    @Published var profile: TxinProfile?
    @Published var deviceId: String = ""
    @Published var systemInfo: TxinSystemInfo?
    @Published var cdnDomesticOK: Bool?

    @Published var blocks: [TxinCategoryBlock] = []
    @Published var artists: [TxinArtist] = []
    @Published var tags: [TxinTagFull] = []
    @Published var page: Int = 1

    @Published var jobs: [DownloadJob] = []
    @Published var statusText: String = "准备中…"
    @Published var errorText: String?

    // MARK: 直接播放（点卡片即播，不下载）

    /// 正在播的标题，nil 表示没在播
    @Published var playingTitle: String?
    /// 交给 VLC 的播放地址（本地明文播放列表）
    @Published var playURL: URL?
    /// 屏幕诊断：每一步的结果，直接显示在播放界面上
    @Published var diag: [String] = []

    func note(_ s: String) {
        let t = String(format: "%02d:%02d ", Int(Date().timeIntervalSince1970) % 3600 / 60,
                       Int(Date().timeIntervalSince1970) % 60)
        diag.append(t + s)
        if diag.count > 12 { diag.removeFirst() }
    }

    private var playTask: Task<Void, Never>?
    /// 后台缓存整片的任务
    private var cacheTask: Task<Void, Never>?

    /// 播放缓存目录（分片 + 本地 m3u8）
    var cacheRoot: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("txin-play", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private(set) var client: TxinClient?

    // MARK: 路径

    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var downloadRoot: URL {
        documentsURL.appendingPathComponent("txin", isDirectory: true)
    }

    var sessionSummary: String {
        """
        user_id: \(profile?.user_id ?? "-")
        username: \(profile?.username ?? "-")
        nickname: \(profile?.nickname ?? "-")
        is_vip: \(profile?.is_vip ?? "-")
        token: \(profile?.token ?? "-")
        deviceId: \(deviceId)
        cdn: \(cdnDomesticOK == true ? "国内直连" : "CloudFront 镜像")
        """
    }

    // MARK: 启动

    func bootstrap() async {
        guard client == nil else { return }
        statusText = "建立会话…"
        do {
            let c = TxinClient()
            try await c.bootstrap()
            self.client = c
            self.profile = await c.profile
            self.deviceId = await c.deviceId

            statusText = "探测 CDN…"
            let ok = await TxinCDN.probeDomestic()
            self.cdnDomesticOK = ok
            await TxinCDN.autoSelectMirror()

            if let info = try? await c.systemInfo() { self.systemInfo = info.data }
            try? FileManager.default.createDirectory(at: downloadRoot,
                                                     withIntermediateDirectories: true)
            await loadHome()
        } catch {
            errorText = "\(error)"
            statusText = "会话建立失败"
        }
    }

    // MARK: 列表

    func loadHome() async {
        guard let c = client else { return }
        statusText = "加载中…"
        do {
            async let movies = c.movieHome(catId: "1", page: page)
            async let artistHome = c.artistHome()
            let (m, a) = try await (movies, artistHome)
            self.blocks = m.data?.data ?? []
            self.artists = a.data?.top_up ?? []
            if tags.isEmpty, let t = try? await c.tags() {
                self.tags = t.data?.data ?? []
            }
            statusText = "\(blocks.reduce(0) { $0 + ($1.items?.count ?? 0) }) 条 · 第 \(page) 页"
        } catch {
            errorText = "\(error)"
            statusText = "加载失败"
        }
    }

    func changePage(_ p: Int) async {
        page = max(1, p)
        await loadHome()
    }

    func movieDetail(id: String) async -> TxinMovieDetail? {
        guard let c = client else { return nil }
        do {
            let r = try await c.movieDetail(id: id)
            return r.data
        } catch {
            errorText = "\(error)"
            return nil
        }
    }

    func probeCDN() async {
        let ok = await TxinCDN.probeDomestic()
        cdnDomesticOK = ok
        await TxinCDN.autoSelectMirror()
        statusText = ok ? "国内 CDN 可用" : "已切 CloudFront 镜像"
    }

    // MARK: - 直接播放（点一下就看，不做任何下载）

    /// 点卡片调它。拉 detail -> 取第一条能通的线路 -> 交给 VLC。
    func play(_ movie: TxinMovieBrief) {
        playTask?.cancel()
        playTask = Task { [weak self] in
            guard let self else { return }
            await self.startPlay(movie)
        }
    }

    private func startPlay(_ movie: TxinMovieBrief) async {
        playingTitle = movie.name ?? movie.id
        errorText = nil
        diag.removeAll()
        note("开始 \(movie.id)")

        guard let detail = await movieDetail(id: movie.id),
              let links = detail.play_links, !links.isEmpty else {
            note("拿不到 play_links")
            errorText = "这部片子拿不到播放地址"
            playingTitle = nil
            return
        }
        note("线路 \(links.count) 条")

        var lastError = ""

        for (idx, link) in links.enumerated() {
            guard let raw = link.m3u8_url else { continue }
            let full = raw.hasPrefix("http") ? raw : TxinEndpoint.current + raw
            note("L\(idx + 1) \(link.code ?? "?") → \(URL(string: full)?.host ?? "?")")

            do {
                let downloader = HLSDownloader(concurrency: 4)
                let playlist = try await downloader.fetchPlaylist(m3u8: full,
                                                                  referer: TxinEndpoint.base)
                note("m3u8 ok 片数=\(playlist.segments.count) key=\(playlist.key != nil ? "有" : "无")")
                note("首片域 \(URL(string: playlist.segments[0])?.host ?? "?")")

                let dir = cacheRoot.appendingPathComponent(movie.id, isDirectory: true)
                let m3u8 = dir.appendingPathComponent("index.m3u8")

                let task = Task.detached(priority: .userInitiated) {
                    _ = try? await downloader.download(playlist, to: dir,
                                                       referer: TxinEndpoint.base,
                                                       onProgress: nil,
                                                       onState: nil)
                }
                cacheTask = task

                var ready = false
                for tick in 0..<80 {
                    let n = Self.segmentCount(dir) ?? 0
                    if tick % 8 == 0 { note("已缓存 \(n)/\(playlist.segments.count) 片") }
                    if n >= 2, FileManager.default.fileExists(atPath: m3u8.path) {
                        ready = true
                        break
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }

                if ready {
                    if let first = Self.firstSegmentHead(dir) {
                        note("首片首字节 \(first) \(first == "0x47" ? "✓明文TS" : "✗异常")")
                    }
                    note("起播 (本地)")
                    playURL = m3u8
                    return
                }
                note("L\(idx + 1) 缓存超时")
                lastError = "线路 \(link.name ?? "") 缓存超时"
            } catch {
                note("L\(idx + 1) 失败 \(error.localizedDescription.prefix(40))")
                lastError = "线路 \(link.name ?? "") \(error.localizedDescription)"
                continue
            }
        }

        errorText = lastError.isEmpty ? "没有可用线路" : lastError
        playingTitle = nil
    }

    private static func firstSegmentHead(_ dir: URL) -> String? {
        let p = dir.appendingPathComponent("seg_0000.ts")
        guard let h = try? FileHandle(forReadingFrom: p) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 1), let b = d.first else { return nil }
        return String(format: "0x%02x", b)
    }


    private static func segmentCount(_ dir: URL) -> Int? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        return names.filter { $0.hasPrefix("seg_") && $0.hasSuffix(".ts") }.count
    }


    /// 直接请求一次 m3u8，看是不是真的 #EXTM3U
    private static func probe(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(TxinClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(TxinEndpoint.base, forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
        let head = String(decoding: data.prefix(64), as: UTF8.self)
        return head.contains("#EXTM3U")
    }

    func stopPlay() {
        playTask?.cancel()
        cacheTask?.cancel()
        playURL = nil
        playingTitle = nil
    }

    // MARK: 下载

    func isDownloading(_ id: String) -> Bool {
        jobs.contains { $0.id == id && ($0.phase == .queued || $0.phase == .playlist || $0.phase == .downloading) }
    }

    func job(for id: String) -> DownloadJob? {
        jobs.first { $0.id == id }
    }

    func startDownload(id: String, title: String) async {
        guard let c = client else { return }
        if isDownloading(id) { return }

        jobs.insert(DownloadJob(id: id, title: title), at: 0)
        let idx = 0

        do {
            let r = try await c.movieDetail(id: id)
            guard let link = r.data?.bestLink, let m3u8 = link.m3u8_url else {
                throw NSError(domain: "txin", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "拿不到播放地址"])
            }
            let full = m3u8.hasPrefix("http") ? m3u8 : TxinEndpoint.current + m3u8
            update(idx) { $0.phase = .playlist }

            let dl = HLSDownloader(concurrency: 4)
            let playlist = try await dl.fetchPlaylist(m3u8: full, referer: TxinEndpoint.base)
            update(idx) { $0.total = playlist.segments.count; $0.phase = .downloading }

            let dir = downloadRoot.appendingPathComponent(id, isDirectory: true)
            let produced = try await dl.download(
                playlist,
                to: dir,
                referer: TxinEndpoint.base,
                onProgress: { p in
                    Task { @MainActor in
                        self.update(idx) { $0.done = p.done; $0.bytes = p.bytes }
                    }
                },
                onState: { s in
                    Task { @MainActor in self.update(idx) { $0.note = s } }
                })

            update(idx) { $0.phase = .merging }
            let safe = title.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            // 保留真实扩展名：remux 成功是 .mp4，失败退回 .ts。
            // 之前这里硬写成 .ts，mp4 被贴上 .ts 后缀，播放器按 TS 解析必然出问题。
            let ext = produced.pathExtension.lowercased()
            let final = dir.appendingPathComponent("\(id)_\(safe).\(ext.isEmpty ? "ts" : ext)")
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: produced, to: final)

            let size = (try? FileManager.default
                .attributesOfItem(atPath: final.path)[.size] as? Int64) ?? 0
            update(idx) {
                $0.phase = .done
                $0.filePath = final.path
                $0.bytes = size
                $0.note = ext == "mp4" ? "已封装为 mp4" : "已合并为 ts"
            }
            statusText = "已保存 \(final.lastPathComponent)"
        } catch {
            update(idx) { $0.phase = .failed; $0.note = "\(error)" }
            errorText = "\(error)"
        }
    }

    private func update(_ idx: Int, _ body: (inout DownloadJob) -> Void) {
        guard jobs.indices.contains(idx) else { return }
        body(&jobs[idx])
    }

    func deleteDownload(_ job: DownloadJob) {
        if let p = job.filePath {
            try? FileManager.default.removeItem(atPath: p)
            let dir = (p as NSString).deletingLastPathComponent
            try? FileManager.default.removeItem(atPath: dir)
        }
        jobs.removeAll { $0.id == job.id }
    }

    func clearFinished() {
        for j in jobs where j.phase == .done || j.phase == .failed {
            if j.phase == .done { deleteDownload(j) }
        }
        jobs.removeAll { $0.phase == .failed }
    }
}
