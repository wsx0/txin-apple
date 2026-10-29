//
//  ContentView.swift
//  TxinApp
//

import SwiftUI
import TxinKit

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab: Tab? = Tab.home

    enum Tab: String, CaseIterable, Identifiable {
        case home = "首页"
        case artists = "艺人"
        case tags = "标签"
        case downloads = "下载"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .home: return "house"
            case .artists: return "person.2"
            case .tags: return "tag"
            case .downloads: return "arrow.down.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: $tab) { t in
                Label(t.rawValue, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
            .safeAreaInset(edge: .bottom) {
                StatusBar()
                    .environmentObject(store)
            }
        } content: {
            Group {
                switch tab ?? .home {
                case .home:     MovieGrid()
                case .artists:  ArtistGrid()
                case .tags:     TagGrid()
                case .downloads: DownloadList()
                }
            }
            .navigationSplitViewColumnWidth(min: 460, ideal: 620)
        } detail: {
            DetailPane()
                .navigationSplitViewColumnWidth(min: 380, ideal: 420)
        }
        .alert("出错了", isPresented: Binding(
            get: { store.errorText != nil },
            set: { if !$0 { store.errorText = nil } })) {
            Button("知道了", role: .cancel) { store.errorText = nil }
        } message: {
            Text(store.errorText ?? "")
        }
    }
}

// MARK: - 状态条

struct StatusBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.profile == nil ? .orange : .green)
                .frame(width: 7, height: 7)
            Text(store.statusText)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            if let ok = store.cdnDomesticOK {
                Text(ok ? "直连" : "CF")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(ok ? Color.green.opacity(0.18) : Color.blue.opacity(0.18))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - 视频网格

struct MovieGrid: View {
    @EnvironmentObject var store: AppStore

    private let columns = [GridItem(.adaptive(minimum: 168), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(store.blocks, id: \.id) { block in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(block.name ?? "-").font(.title3.bold())
                            if let intro = block.intro, !intro.isEmpty {
                                Text(intro).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(block.items ?? []) { m in
                                MovieCard(movie: m)
                                    .onTapGesture { store.select(m) }
                            }
                        }
                    }
                }
                PageBar()
            }
            .padding(16)
        }
    }
}

struct MovieCard: View {
    let movie: TxinMovieBrief
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                RemoteImage(url: movie.img, contentMode: .fill) {
                    ImagePlaceholder()
                }
                .frame(height: 106)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if movie.isPaid {
                    Text("VIP")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .padding(5)
                }
            }

            Text(movie.name ?? "-")
                .font(.callout)
                .lineLimit(2)
                .frame(height: 34, alignment: .top)

            HStack(spacing: 8) {
                Label(movie.click ?? "-", systemImage: "play.circle")
                Label(movie.love ?? "-", systemImage: "heart")
                Spacer()
                Text(movie.duration ?? "")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(hover ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
    }
}

struct PageBar: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 12) {
            Button("上一页") { Task { await store.changePage(store.page - 1) } }
                .disabled(store.page <= 1)
            Text("第 \(store.page) 页").font(.caption).foregroundStyle(.secondary)
            Button("下一页") { Task { await store.changePage(store.page + 1) } }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

// MARK: - 艺人

struct ArtistGrid: View {
    @EnvironmentObject var store: AppStore
    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(store.artists) { a in
                    VStack(alignment: .leading, spacing: 6) {
                        RemoteImage(url: a.headico, contentMode: .fill) {
                            ImagePlaceholder(icon: "person.fill")
                        }
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Text(a.nickname ?? "-").font(.callout.bold())
                        Text(a.intro ?? "")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        HStack(spacing: 10) {
                            if let f = a.tangxin_fans_count { Label(f, systemImage: "person.3") }
                            if let w = a.works_count { Label(w, systemImage: "film") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(6)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 标签

struct TagGrid: View {
    @EnvironmentObject var store: AppStore
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(store.tags) { t in
                    Text(t.name ?? "-")
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
    }
}

// MARK: - 下载

struct DownloadList: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        List {
            if store.jobs.isEmpty {
                Text("还没有下载任务").foregroundStyle(.secondary)
            }
            ForEach(store.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(job.title).font(.callout.bold()).lineLimit(1)
                        Spacer()
                        Text(job.state.rawValue).font(.caption2).foregroundStyle(.secondary)
                    }
                    if job.total > 0 {
                        ProgressView(value: job.fraction)
                    }
                    HStack(spacing: 12) {
                        Text("\(job.done)/\(job.total)").font(.caption2)
                        Text(job.sizeText).font(.caption2)
                        if !job.stateText.isEmpty {
                            Text(job.stateText).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let p = job.filePath {
                            Button("在 Finder 中显示") { store.revealInFinder(p) }
                                .buttonStyle(.link)
                                .font(.caption2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
