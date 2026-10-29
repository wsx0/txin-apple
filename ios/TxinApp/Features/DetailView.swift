//
//  DetailView.swift
//  Txin （iOS）
//

import SwiftUI
import AVKit

struct DetailView: View {
    let movie: TxinMovieBrief

    @EnvironmentObject private var store: AppStore
    @State private var detail: TxinMovieDetail?
    @State private var player: AVPlayer?
    @State private var playingLine: String?
    @State private var loading = true
    /// 必须强引用：AVAssetResourceLoader 只持弱引用
    @State private var resLoader: TxinResourceLoader?
    @State private var stallNote: String = ""

    private var job: DownloadJob? { store.job(for: movie.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                poster

                header

                if let p = player {
                    VideoPlayer(player: p)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                lines

                actions

                if let d = detail, let desc = d.description,
                   !desc.isEmpty, desc != "当前暂无简介" {
                    Text(desc)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 30)
        }
        .navigationTitle(movie.name ?? "详情")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard detail == nil else { return }
            detail = await store.movieDetail(id: movie.id)
            loading = false
        }
        .onDisappear {
            player?.pause()
            player = nil
            playingLine = nil
        }
    }

    // MARK: 组件

    private var poster: some View {
        RemoteImage(url: movie.img, contentMode: .fit) {
            ImagePlaceholder(icon: "film")
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail?.name ?? movie.name ?? "-")
                .font(.title3.bold())
            HStack(spacing: 10) {
                if movie.isPaid {
                    Text("VIP")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if let c = detail?.category?.name { Text(c) }
                if let d = detail?.duration ?? movie.duration { Text(d) }
                if let c = detail?.click ?? movie.click {
                    Label(c, systemImage: "play.circle")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var lines: some View {
        let links = detail?.play_links ?? []
        return Group {
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 8) {

                    // ── 直接播放（不下载）──────────────────────────
                    Text("直接播放").font(.caption.bold()).foregroundStyle(.secondary)

                    ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                        Button {
                            playRemote(line: l)
                        } label: {
                            HStack {
                                Image(systemName: playingLine == l.code
                                      ? "stop.circle.fill" : "play.circle.fill")
                                Text(l.name ?? l.code ?? "线路")
                                Spacer()
                                if playingLine == l.code {
                                    Text("播放中").font(.system(size: 9))
                                }
                            }
                            .font(.footnote)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(playingLine == l.code ? .red : .pink)
                    }

                    if !stallNote.isEmpty {
                        Text(stallNote)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }

                    Text("边看边拉，全部子请求经本地代理转发（带齐 Referer，避免 403）。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)

                    Divider().padding(.vertical, 2)

                    // ── 缓存到本地 ─────────────────────────────────
                    if localFile != nil {
                        HStack(spacing: 6) {
                            Label("已缓存整片", systemImage: "internaldrive.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.green)
                            Spacer()
                            Text(localFile?.lastPathComponent ?? "")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Button {
                            play(line: links[0])
                        } label: {
                            HStack {
                                Image(systemName: playingLine == "local"
                                      ? "stop.circle.fill" : "play.circle.fill")
                                Text(playingLine == "local" ? "停止" : "播放已缓存")
                                Spacer()
                            }
                            .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .tint(playingLine == "local" ? .red : .green)

                    } else if let job = job, downloadedSegments > 0 {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("已缓存 \(downloadedSegments)/\(max(job.total, 1)) 片")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("播放缓存") { play(line: links[0]) }
                                .font(.system(size: 10))
                        }

                    } else if job == nil {
                        Button {
                            Task { await store.startDownload(id: movie.id, title: movie.name ?? movie.id) }
                        } label: {
                            Label("后台缓存整片（可选）", systemImage: "arrow.down.circle")
                                .font(.footnote)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(job?.phase.rawValue ?? "")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if let j = job {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(j.phase.rawValue).font(.caption.bold())
                        Spacer()
                        Text("\(j.done)/\(j.total)  \(j.sizeText)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if j.total > 0 {
                        ProgressView(value: j.fraction)
                    }
                    if !j.note.isEmpty {
                        Text(j.note).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                    }
                    if let url = j.fileURL {
                        ShareLink(item: url) {
                            Label("导出 / 分享", systemImage: "square.and.arrow.up")
                                .font(.footnote)
                        }
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 6) {
                    Button {
                        Task { await store.startDownload(id: movie.id, title: movie.name ?? movie.id) }
                    } label: {
                        Label("下载完整视频", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.pink)

                    Text("CDN 带宽不稳时直接播会中途断流。下载完是本地文件，想看几遍看几遍。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
    }

    /// 已下载的本地文件路径（优先播它）
    private var localFile: URL? {
        guard let job = store.job(for: movie.id),
              job.phase == .done,
              let path = job.filePath,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// 本地 HLS 播放列表。
    /// 注意：这里**不看 job.phase**，只要文件存在就返回 —— 因为要支持边下边播，
    /// 下载中的分片是连续落盘的，m3u8 也在增量刷新。
    private var localPlaylist: URL? {
        let m3u8 = store.downloadRoot
            .appendingPathComponent(movie.id, isDirectory: true)
            .appendingPathComponent("index.m3u8")
        return FileManager.default.fileExists(atPath: m3u8.path) ? m3u8 : nil
    }

    /// 已经落盘的分片数
    private var downloadedSegments: Int {
        let d = store.downloadRoot.appendingPathComponent(movie.id, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: d.path) else { return 0 }
        return names.filter { $0.hasPrefix("seg_") && $0.hasSuffix(".ts") }.count
    }

    /// 直接播远程 m3u8 —— 走 TxinResourceLoader 代理，所有子请求都带齐 header
    private func playRemote(line: TxinPlayLink) {
        if playingLine == line.code {
            player?.pause(); player = nil; playingLine = nil; resLoader = nil
            return
        }
        guard let raw = line.m3u8_url else { return }
        let full = raw.hasPrefix("http") ? raw : TxinEndpoint.current + raw
        guard let url = URL(string: full),
              let proxied = TxinResourceLoader.encode(url) else { return }

        // 关键：AVURLAssetHTTPHeaderFieldsKey 只管主请求，分片/key 请求不带 Referer，
        // CDN 会 403 —— 这就是「播几秒就停」。换成 resource loader 全量接管。
        let loader = TxinResourceLoader(referer: TxinEndpoint.base)
        resLoader = loader

        let asset = AVURLAsset(url: proxied)
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "txin.resource-loader"))

        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 30      // 预缓冲 30 秒，抗抖动
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true

        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true   // 卡住时等缓冲，而不是直接停
        player = p
        playingLine = line.code
        stallNote = ""
        p.play()

        // 监听状态，卡住时给用户一句话
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item, queue: .main) { _ in
                stallNote = "网络跟不上，正在缓冲…"
            }
    }

    private func play(line: TxinPlayLink) {
        if playingLine == "local" {
            player?.pause(); player = nil; playingLine = nil
            return
        }

        // 1) 本地 HLS 播放列表（下载中也能播，播到未下载的分片会自己等）
        if let pl = localPlaylist {
            player = AVPlayer(url: pl)
            playingLine = "local"
            player?.play()
            return
        }

        // 2) mp4
        if let f = localFile, f.pathExtension.lowercased() == "mp4" {
            player = AVPlayer(url: f)
            playingLine = "local"
            player?.play()
            return
        }

        // 3) 整片 ts（老版本）
        if let local = localFile {
            let asset = AVURLAsset(url: local, options: [
                "AVURLAssetOutOfBandMIMETypeKey": "video/mp2t",
            ])
            let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            player = p
            playingLine = "local"
            p.play()
            return
        }

        // 4) 远程流播（走 loader）
        playRemote(line: line)
    }
}
