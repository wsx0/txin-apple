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
    /// 交给全屏播放器的 item
    @Published var playerItem: AVPlayerItem?

    /// 必须强引用：AVAssetResourceLoader 只持弱引用，loader 一释放播放就断
    private var resLoader: TxinResourceLoader?
    private var playTask: Task<Void, Never>?

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

    /// 点卡片调它。拉 detail -> 取第一条线路 -> 走 resource loader 播放。
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

        guard let detail = await movieDetail(id: movie.id),
              let links = detail.play_links, !links.isEmpty else {
            errorText = "这部片子拿不到播放地址"
            playingTitle = nil
            return
        }

        // 两条线路的 hash 不同、走不同 CDN 节点，随便挑一条能通的
        var lastError: String = ""
        for link in links {
            guard let raw = link.m3u8_url else { continue }
            let full = raw.hasPrefix("http") ? raw : TxinEndpoint.current + raw
            guard let url = URL(string: full),
                  let proxied = TxinResourceLoader.encode(url) else { continue }

            // 关键：AVURLAssetHTTPHeaderFieldsKey 只作用于主请求，
            // HLS 的分片和 key 是 AVFoundation 自己发的，不带 Referer -> CDN 403 -> 只播几秒。
            // resource loader 接管全部子请求，统一补 header。
            let loader = TxinResourceLoader(referer: TxinEndpoint.base)
            resLoader = loader

            let asset = AVURLAsset(url: proxied)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "txin.resource-loader"))

            // 先探一下这个 m3u8 能不能真的拿到（避免用户对着黑屏等）
            let ok = await loader.probePlaylist(url)
            guard ok else {
                lastError = "线路 \(link.name ?? "") 拉不到播放列表"
                continue
            }

            let item = AVPlayerItem(asset: asset)
            item.preferredForwardBufferDuration = 30
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            playerItem = item
            return
        }

        errorText = lastError.isEmpty ? "所有线路都打不开" : lastError
        playingTitle = nil
    }

    func stopPlay() {
        playTask?.cancel()
        playerItem = nil
        playingTitle = nil
        resLoader?.clearCache()
        resLoader = nil
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
