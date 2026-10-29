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
                VStack(alignment: .leading, spacing: 6) {
                    if localFile != nil {
                        // 已下载：只给一个"播放本地视频"入口，不走网络
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
                    } else {
                        // 没下载：不提供流播入口。
                        // CDN 带宽不稳时直接流播必然中途断，与其让人误点，不如不给。
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text("要先下载才能播放 —— CDN 流播在手机网络上撑不住")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
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

    /// 下载目录里的本地 HLS 播放列表 —— 比裸 .ts 稳得多
    private var localPlaylist: URL? {
        guard let f = localFile else { return nil }
        let m3u8 = f.deletingLastPathComponent().appendingPathComponent("index.m3u8")
        return FileManager.default.fileExists(atPath: m3u8.path) ? m3u8 : nil
    }

    private func play(line: TxinPlayLink) {
        if playingLine == "local" {
            player?.pause(); player = nil; playingLine = nil
            return
        }

        // 1) 本地 HLS 播放列表永远排第一。
        //    分片是解密后的明文，AVPlayer 按 m3u8 逐片读，每片独立解析，
        //    不会碰「多个 PAT/PMT program」那个坑 —— 这是目前最稳的播放路径。
        if let pl = localPlaylist {
            player = AVPlayer(url: pl)
            playingLine = "local"
            player?.play()
            return
        }

        // 2) mp4（remux 通过时长校验才会存在）
        if let f = localFile, f.pathExtension.lowercased() == "mp4" {
            player = AVPlayer(url: f)
            playingLine = "local"
            player?.play()
            return
        }

        // 3) 只剩整片 .ts（老版本下载的）
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

        // 4) 没下载才走远程流播
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
