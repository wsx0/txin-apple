//
//  DownloadsView.swift
//  Txin （iOS）
//
//  这一版加了「诊断」和「系统播放器播放」：
//    · 诊断：列出下载目录里每个文件的大小，看清 remux 到底成没成
//    · 系统播放器：用 AVPlayerViewController 全屏，绕开内嵌 VideoPlayer 的坑
//

import SwiftUI
import AVKit

struct DownloadsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingDelete: DownloadJob?
    @State private var diagnose: DownloadJob?
    @State private var playerItem: AVPlayerItem?

    var body: some View {
        NavigationStack {
            List {
                if store.jobs.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "还没有下载",
                        systemImage: "arrow.down.circle",
                        hint: "在首页点开作品，按「下载完整视频」")
                }

                ForEach(store.jobs) { job in
                    DownloadRow(job: job)
                        .contentShape(Rectangle())
                        .onTapGesture { diagnose = job }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDelete = job } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if job.phase == .done {
                                Button { openPlayer(job) } label: {
                                    Label("播放", systemImage: "play.fill")
                                }
                                .tint(.green)
                            }
                        }
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清理") { store.clearFinished() }
                        .disabled(store.jobs.isEmpty)
                }
            }
            .sheet(item: $diagnose) { job in
                DiagnoseSheet(job: job, onPlay: { openPlayer(job) })
                    .environmentObject(store)
            }
            .fullScreenCover(item: Binding(
                get: { playerItem.map { PlayerBox(item: $0) } },
                set: { if $0 == nil { playerItem = nil } })) { box in
                SystemPlayerView(item: box.item) { playerItem = nil }
            }
            .confirmationDialog("删除这个下载？",
                                isPresented: Binding(
                                    get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
                                presenting: pendingDelete) { job in
                Button("删除文件", role: .destructive) {
                    store.deleteDownload(job)
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { job in Text(job.title) }
        }
    }

    private func openPlayer(_ job: DownloadJob) {
        guard let path = job.filePath else { return }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()

        // 优先 remux 出来的 mp4，其次本地 m3u8
        let mp4 = dir.appendingPathComponent("video.mp4")
        let m3u8 = dir.appendingPathComponent("index.m3u8")
        let target: URL
        if FileManager.default.fileExists(atPath: mp4.path) {
            target = mp4
        } else if FileManager.default.fileExists(atPath: m3u8.path) {
            target = m3u8
        } else {
            target = URL(fileURLWithPath: path)
        }
        playerItem = AVPlayerItem(url: target)
    }
}

// MARK: - 系统播放器（AVPlayerViewController）

struct PlayerBox: Identifiable {
    let item: AVPlayerItem
    var id: ObjectIdentifier { ObjectIdentifier(item) }
}

struct SystemPlayerView: UIViewControllerRepresentable {
    let item: AVPlayerItem
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let player = AVPlayer(playerItem: item)
        vc.player = player
        vc.showsPlaybackControls = true
        player.play()

        // 记住时长，方便诊断
        context.coordinator.player = player
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator {
        var player: AVPlayer?
        let onDismiss: () -> Void
        init(onDismiss: @escaping () -> Void) { self.onDismiss = onDismiss }
    }
}

// MARK: - 诊断面板

struct DiagnoseSheet: View {
    let job: DownloadJob
    let onPlay: () -> Void

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [FileRow] = []
    @State private var summary: String = ""
    @State private var mediaInfo: [MediaInfo] = []

    struct FileRow: Identifiable {
        let id = UUID()
        let name: String
        let bytes: Int64
        let note: String
    }

    struct MediaInfo: Identifiable {
        let id = UUID()
        let name: String
        let duration: String
        let tracks: String
        let verdict: String
        let ok: Bool
    }

    var body: some View {
        NavigationStack {
            List {
                Section("状态") {
                    row("阶段", job.phase.rawValue)
                    row("说明", job.note.isEmpty ? "-" : job.note)
                    row("进度", "\(job.done)/\(job.total)")
                    row("大小", job.sizeText)
                }

                // 决定性诊断：文件自己报的时长和轨道数
                Section("媒体探针") {
                    if mediaInfo.isEmpty {
                        Text("扫描中…").foregroundStyle(.secondary)
                    }
                    ForEach(mediaInfo) { m in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(m.name).font(.footnote.monospaced())
                                Spacer()
                                Text(m.ok ? "OK" : "异常")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(m.ok ? .green : .red)
                            }
                            Text("时长 \(m.duration)   轨道 \(m.tracks)")
                                .font(.system(size: 11))
                            Text(m.verdict)
                                .font(.system(size: 10))
                                .foregroundStyle(m.ok ? .secondary : .orange)
                        }
                    }
                }

                Section("目录内容 \(summary)") {
                    if rows.isEmpty {
                        Text("目录为空或还没扫描").foregroundStyle(.secondary)
                    }
                    ForEach(rows) { r in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.name).font(.footnote.monospaced())
                                if !r.note.isEmpty {
                                    Text(r.note).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(fmt(r.bytes))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button {
                        onPlay()
                        dismiss()
                    } label: {
                        Label("用系统播放器打开", systemImage: "play.rectangle.fill")
                    }
                    .disabled(job.phase != .done)

                    Button {
                        Task { await scan() }
                    } label: {
                        Label("重新扫描", systemImage: "arrow.clockwise")
                    }
                }
            }
            .navigationTitle("下载详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await scan() }
        }
    }

    // MARK: - 扫描

    private func scan() async {
        guard let path = job.filePath else { rows = []; return }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
            rows = []; return
        }
        var out: [FileRow] = []
        var segBytes: Int64 = 0
        var segCount = 0
        for n in names.sorted() {
            let p = dir.appendingPathComponent(n)
            let size = (try? fm.attributesOfItem(atPath: p.path)[.size] as? Int64) ?? 0
            var note = ""
            if n.hasSuffix(".mp4") {
                note = "remux 结果"
            } else if n.hasSuffix(".m3u8") {
                let txt = (try? String(contentsOf: p, encoding: .utf8)) ?? ""
                let nInf = txt.components(separatedBy: "#EXTINF").count - 1
                note = "播放列表，\(nInf) 条 EXTINF"
            } else if n.hasPrefix("seg_") {
                segCount += 1
                segBytes += size
                continue
            } else if n.hasSuffix(".ts") {
                note = "合并整片"
            }
            out.append(FileRow(name: n, bytes: size, note: note))
        }
        if segCount > 0 {
            out.append(FileRow(name: "seg_*.ts × \(segCount)",
                               bytes: segBytes,
                               note: "解密后的分片"))
        }
        let errFile = dir.appendingPathComponent("remux-error.txt")
        if let txt = try? String(contentsOf: errFile, encoding: .utf8) {
            out.append(FileRow(name: "remux-error.txt",
                               bytes: Int64(txt.utf8.count),
                               note: txt == "ok" ? "remux 成功" : txt))
        }
        rows = out
        summary = "(\(names.count) 个文件)"

        // 探针：对每个媒体文件读真实 info
        var infos: [MediaInfo] = []
        for n in names.sorted() {
            guard n.hasSuffix(".mp4") || n.hasSuffix(".ts") || n.hasPrefix("seg_0000") else { continue }
            let u = dir.appendingPathComponent(n)
            infos.append(await probe(u, name: n))
        }
        // 播放列表也探一下（AVURLAsset 能读 HLS 时长）
        let m3u8 = dir.appendingPathComponent("index.m3u8")
        if fm.fileExists(atPath: m3u8.path) {
            infos.append(await probe(m3u8, name: "index.m3u8"))
        }
        mediaInfo = infos
    }

    private func probe(_ url: URL, name: String) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        var durText = "?"
        var trackText = "?"
        var verdict = ""
        var ok = false
        do {
            let dur = try await asset.load(.duration).seconds
            durText = String(format: "%.1f s", dur)
            let v = (try? await asset.loadTracks(withMediaType: .video))?.count ?? 0
            let a = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
            trackText = "v\(v)/a\(a)"
            // 判定：时长 > 60 秒且轨道正常
            if dur.isFinite && dur > 60 && v >= 1 {
                ok = true
                verdict = "时长和轨道都正常 —— 播放器只播几秒的话，问题在播放侧"
            } else if dur.isFinite && dur > 0 {
                verdict = "时长只有 \(String(format: "%.1f", dur)) 秒 —— 文件本身被截断了"
            } else {
                verdict = "读不出时长 —— 容器结构有问题"
            }
        } catch {
            verdict = "探针失败: \(error)"
        }
        return MediaInfo(name: name, duration: durText, tracks: trackText,
                         verdict: verdict, ok: ok)
    }

    private func fmt(_ b: Int64) -> String {
        if b >= 1_048_576 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        if b >= 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
        return "\(b) B"
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.footnote).multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 行

struct DownloadRow: View {
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.title).font(.footnote.bold()).lineLimit(1)
                Spacer()
                Text(job.phase.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
            }

            if job.total > 0 && (job.phase == .downloading || job.phase == .merging) {
                ProgressView(value: job.fraction).tint(.pink)
            }

            HStack(spacing: 10) {
                if job.total > 0 { Text("\(job.done)/\(job.total)") }
                Text(job.sizeText)
                if !job.note.isEmpty { Text(job.note).lineLimit(1) }
                Spacer()
                if job.phase == .done {
                    Text("点击查看详情").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var color: Color {
        switch job.phase {
        case .done:   return .green
        case .failed: return .red
        default:      return .secondary
        }
    }
}

/// iOS 16 没有 ContentUnavailableView
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let hint: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout)
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}
