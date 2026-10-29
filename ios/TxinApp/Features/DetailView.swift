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
                    if localFile != nil {
                        // 全部下完
                        HStack(spacing: 6) {
                            Label("本地文件", systemImage: "internaldrive.fill")
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
                                Text(playingLine == "local" ? "停止" : "播放本地视频")
                                Spacer()
                            }
                            .font(.footnote)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(playingLine == "local" ? .red : .green)

                    } else if let job = job, downloadedSegments > 0 {
                        // 下载中：可以立刻边下边播
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("已缓存 \(downloadedSegments)/\(max(job.total, 1)) 片")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            play(line: links[0])
                        } label: {
                            HStack {
                                Image(systemName: playingLine == "local"
                                      ? "stop.circle.fill" : "play.circle.fill")
                                Text(playingLine == "local" ? "停止" : "边下边播")
                                Spacer()
                            }
                            .font(.footnote)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(playingLine == "local" ? .red : .orange)

                    } else if let job = job {
                        // 刚点下载，还没拿到第一个分片
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text(job.phase.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }

                    } else {
                        // 还没开始：一个按钮搞定「开始缓存 + 立即播放」
                        Button {
                            Task {
                                await store.startDownload(id: movie.id, title: movie.name ?? movie.id)
                                // 等第一个分片落盘就给播放器
                                for _ in 0..<40 {
                                    try? await Task.sleep(nanoseconds: 250_000_000)
                                    if downloadedSegments >= 2 { break }
                                }
                                play(line: links[0])
                            }
                        } label: {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text("边下边播")
                                Spacer()
                            }
                            .font(.footnote)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.pink)

                        Text("先缓存两三个分片就开始播，后面边下边拉，不用等整片下完。")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
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

        // 4) 远程流播
        guard let raw = line.m3u8_url else { return }
        if playingLine == line.code {
            player?.pause(); player = nil; playingLine = nil
            return
        }
        let full = raw.hasPrefix("http") ? raw : TxinEndpoint.current + raw
        guard let url = URL(string: full) else { return }

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": TxinClient.userAgent,
                "Referer": TxinEndpoint.base,
            ]
        ])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = p
        playingLine = line.code
        p.play()
    }
}
