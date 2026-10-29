//
//  AppStore.swift
//  TxinApp
//
//  全部状态集中在这里：会话、列表、选中项、下载队列、CDN 状态。
//

import Foundation
import SwiftUI
import AppKit
import TxinKit

@MainActor
final class AppStore: ObservableObject {

    // 会话
    @Published var profile: TxinProfile?
    @Published var deviceId: String = ""
    @Published var systemInfo: TxinSystemInfo?
    @Published var cdnDomesticOK: Bool?
    @Published var statusText: String = "准备中…"
    @Published var errorText: String?

    // 列表
    @Published var blocks: [TxinCategoryBlock] = []
    @Published var artists: [TxinArtist] = []
    @Published var tags: [TxinTagFull] = []
    @Published var page: Int = 1

    // 选中
    @Published var selectedMovie: TxinMovieBrief?
    @Published var detail: TxinMovieDetail?

    // 下载
    @Published var jobs: [DownloadJob] = []

    private(set) var client: TxinClient?

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

    // MARK: - 启动

    func bootstrap() async {
        guard client == nil else { return }
        statusText = "建立会话…"
        let c = TxinClient()
        do {
            try await c.bootstrap()
            self.client = c
            self.profile = await c.profile
            self.deviceId = await c.deviceId

            statusText = "探测 CDN…"
            let ok = await TxinCDN.probeDomestic()
            self.cdnDomesticOK = ok
            await TxinCDN.autoSelectMirror()

            statusText = "拉取站点信息…"
            if let info = try? await c.systemInfo() { self.systemInfo = info.data }

            await loadHome()
        } catch {
            errorText = "\(error)"
            statusText = "会话建立失败"
        }
    }

    // MARK: - 列表

    func loadHome() async {
        guard let c = client else { return }
        statusText = "加载列表…"
        do {
            async let movies = c.movieHome(catId: "1", page: page)
            async let artistHome = c.artistHome()
            let (m, a) = try await (movies, artistHome)
            self.blocks = m.data?.data ?? []
            self.artists = a.data?.top_up ?? []
            if tags.isEmpty, let t = try? await c.tags() {
                self.tags = t.data?.data ?? []
            }
            statusText = "共 \(blocks.reduce(0) { $0 + ($1.items?.count ?? 0) }) 条 · 第 \(page) 页"
        } catch {
            errorText = "\(error)"
            statusText = "加载失败"
        }
    }

    func changePage(_ p: Int) async {
        page = max(1, p)
        await loadHome()
    }

    func select(_ movie: TxinMovieBrief) {
        selectedMovie = movie
        detail = nil
        Task { await loadDetail(id: movie.id) }
    }

    func loadDetail(id: String) async {
        guard let c = client else { return }
        do {
            let r = try await c.movieDetail(id: id)
            if let d = r.data { self.detail = d }
        } catch {
            errorText = "\(error)"
        }
    }

    // MARK: - CDN

    func probeCDN() async {
        let ok = await TxinCDN.probeDomestic()
        cdnDomesticOK = ok
        await TxinCDN.autoSelectMirror()
        statusText = ok ? "国内 CDN 可用" : "国内 CDN 被劫持，已切 CloudFront"
    }

    // MARK: - 下载

    func download(_ movie: TxinMovieBrief) {
        Task { await startDownload(id: movie.id, title: movie.name ?? movie.id) }
    }

    func startDownload(id: String, title: String) async {
        guard let c = client else { return }
        if jobs.contains(where: { $0.id == id && $0.state != .failed && $0.state != .done }) { return }

        let job = DownloadJob(id: id, title: title)
        jobs.insert(job, at: 0)

        do {
            let r = try await c.movieDetail(id: id)
            guard let link = r.data?.bestLink, let m3u8 = link.m3u8_url else {
                throw NSError(domain: "txin", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "拿不到播放地址"])
            }
            let full = m3u8.hasPrefix("http") ? m3u8 : TxinEndpoint.current + m3u8
            job.state = .fetchingPlaylist

            let dl = HLSDownloader(concurrency: 6)
            let playlist = try await dl.fetchPlaylist(m3u8: full, referer: TxinEndpoint.base)
            job.total = playlist.segments.count
            job.state = .downloading

            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/txin/\(id)")
            let merged = try await dl.download(
                playlist,
                to: dir,
                referer: TxinEndpoint.base,
                onProgress: { p in
                    Task { @MainActor in
                        job.done = p.done
                        job.bytes = p.bytes
                    }
                },
                onState: { s in
                    Task { @MainActor in job.stateText = s }
                })

            let safe = title.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "_")
            let final = dir.appendingPathComponent("\(id)_\(safe).ts")
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: merged, to: final)

            job.filePath = final.path
            job.state = .done
            job.bytes = (try? FileManager.default
                .attributesOfItem(atPath: final.path)[.size] as? Int64) ?? job.bytes
            statusText = "已保存 \(final.lastPathComponent)"
        } catch {
            job.state = .failed
            job.stateText = "\(error)"
            errorText = "\(error)"
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

// MARK: - 下载任务

@MainActor
final class DownloadJob: ObservableObject, Identifiable {
    enum State: String {
        case queued, fetchingPlaylist, downloading, done, failed
    }

    let id: String
    let title: String
    @Published var state: State = .queued
    @Published var done: Int = 0
    @Published var total: Int = 0
    @Published var bytes: Int64 = 0
    @Published var stateText: String = ""
    @Published var filePath: String?

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var sizeText: String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
}
