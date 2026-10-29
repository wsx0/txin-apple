//
//  HomeView.swift
//  Txin （iOS）
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selected: TxinMovieBrief?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(store.blocks, id: \.id) { block in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(block.name ?? "-")
                                    .font(.headline)
                                if let intro = block.intro, !intro.isEmpty {
                                    Text(intro)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            LazyVGrid(columns: columns, spacing: 10) {
                                ForEach(block.items ?? []) { m in
                                    // 点一下就播 —— 不进详情页、不下载
                                    Button {
                                        store.play(m)
                                    } label: {
                                        MovieCell(movie: m)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    PageBar()
                        .padding(.top, 8)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
            .navigationTitle("糖心")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.loadHome() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .refreshable { await store.loadHome() }
            .safeAreaInset(edge: .bottom) {
                StatusStrip()
            }
        }
    }
}

// MARK: - 卡片

struct MovieCell: View {
    let movie: TxinMovieBrief

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                RemoteImage(url: movie.img, contentMode: .fill) {
                    ImagePlaceholder()
                }
                .frame(height: 96)
                .frame(maxWidth: .infinity)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))

                if movie.isPaid {
                    Text("VIP")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color.orange)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .padding(4)
                }
            }

            Text(movie.name ?? "-")
                .font(.caption)
                .lineLimit(2)
                .frame(height: 30, alignment: .top)

            HStack(spacing: 6) {
                Image(systemName: "play.circle")
                Text(movie.click ?? "-")
                Spacer()
                Text(movie.duration ?? "")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }
}

struct PageBar: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 20) {
            Button {
                Task { await store.changePage(store.page - 1) }
            } label: {
                Label("上一页", systemImage: "chevron.left")
            }
            .disabled(store.page <= 1)

            Text("\(store.page)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                Task { await store.changePage(store.page + 1) }
            } label: {
                Label("下一页", systemImage: "chevron.right")
            }
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
    }
}

struct StatusStrip: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.profile == nil ? .orange : .green)
                .frame(width: 6, height: 6)
            Text(store.statusText)
                .font(.caption2)
                .lineLimit(1)
            Spacer()
            if let ok = store.cdnDomesticOK {
                Text(ok ? "直连" : "CF")
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(ok ? Color.green.opacity(0.2) : Color.blue.opacity(0.2))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial)
    }
}

// MARK: - 艺人

struct ArtistsView: View {
    @EnvironmentObject private var store: AppStore
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(store.artists) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            RemoteImage(url: a.headico, contentMode: .fill) {
                                ImagePlaceholder(icon: "person.fill")
                            }
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            Text(a.nickname ?? "-").font(.caption.bold())
                            if let f = a.tangxin_fans_count {
                                Label(f, systemImage: "person.3")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle("艺人")
        }
    }
}
