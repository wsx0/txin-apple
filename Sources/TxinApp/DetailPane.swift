//
//  DetailPane.swift
//  TxinApp
//
//  右侧详情：封面、元信息、AVPlayer 直接播 m3u8、下载按钮。
//

import SwiftUI
import AVKit
import TxinKit

struct DetailPane: View {
    @EnvironmentObject private var store: AppStore
    @State private var player: AVPlayer?
    @State private var playingLine: String?

    var body: some View {
        ScrollView {
            if let d = store.detail {
                VStack(alignment: .leading, spacing: 14) {
                    header(d)
                    if let player {
                        VideoPlayer(player: player)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else if let cover = d.coverURL {
                        AsyncImage(url: cover) { phase in
                            if let img = phase.image {
                                img.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Rectangle().fill(.quaternary)
                                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    lines(d)

                    HStack {
                        Button {
                            store.download(TxinMovieBrief(
                                id: d.id, name: d.name, img: d.img, duration: d.duration,
                                click: d.click, love: d.love, favorite: d.favorite,
                                pay_type: d.pay_type, money: d.money, kouling: nil,
                                category: d.category?.name, show_at: d.show_at, tags: d.tags))
                        } label: {
                            Label("下载并解密", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)

                        if let p = store.jobs.first(where: { $0.id == d.id && $0.state == .done })?.filePath {
                            Button {
                                store.revealInFinder(p)
                            } label: {
                                Label("打开文件", systemImage: "folder")
                            }
                        }
                    }

                    if let desc = d.description, !desc.isEmpty, desc != "当前暂无简介" {
                        Text(desc)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let tags = d.tags, !tags.isEmpty {
                        FlowRow(tags.map { $0.name ?? "-" })
                    }
                }
                .padding(16)
            } else if let m = store.selectedMovie {
                ProgressView("加载 \(m.name ?? m.id)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(40)
            } else {
                ContentUnavailablePlaceholder()
            }
        }
    }

    @ViewBuilder
    private func header(_ d: TxinMovieDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(d.name ?? "-").font(.title2.bold())
            HStack(spacing: 10) {
                if d.isPaid {
                    Text("VIP")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.orange).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if let c = d.category?.name { Text(c) }
                if let dur = d.duration { Text(dur) }
                if let c = d.click { Label(c, systemImage: "play.circle") }
                if let f = d.favorite { Label(f, systemImage: "bookmark") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func lines(_ d: TxinMovieDetail) -> some View {
        let links = d.play_links ?? []
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("线路").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(links.enumerated()), id: \.offset) { _, l in
                    HStack {
                        Button {
                            play(line: l)
                        } label: {
                            Label(l.name ?? l.code ?? "线路",
                                  systemImage: playingLine == l.code ? "stop.circle" : "play.circle")
                        }
                        .buttonStyle(.bordered)
                        .tint(playingLine == l.code ? .red : .accentColor)
                        Spacer()
                        Text(l.m3u8_url ?? "")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func play(line: TxinPlayLink) {
        guard let raw = line.m3u8_url else { return }
        if playingLine == line.code {
            player?.pause()
            player = nil
            playingLine = nil
            return
        }
        let full = raw.hasPrefix("http") ? raw : TxinEndpoint.current + raw
        guard let url = URL(string: full) else { return }

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": TxinClient.userAgent,
                "Referer": TxinEndpoint.base,
            ],
        ])
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        player = p
        playingLine = line.code
        p.play()
    }
}

// MARK: - 小工具

struct ContentUnavailablePlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("选一个作品看详情").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// 标签横向滚动条
struct FlowRow: View {
    let items: [String]
    init(_ items: [String]) { self.items = items }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, t in
                    Text(t)
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.14))
                        .clipShape(Capsule())
                }
            }
            .padding(.vertical, 2)
        }
    }
}
