//
//  RootView.swift
//  Txin （iOS）
//
//  极简形态：首页点卡片 -> 直接全屏播。播放内核是 VLCKit（libVLC + FFmpeg）。
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var tab: Int = 0

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(0)

            ArtistsView()
                .tabItem { Label("艺人", systemImage: "person.2.fill") }
                .tag(1)

            SettingsView()
                .tabItem { Label("我的", systemImage: "gearshape.fill") }
                .tag(2)
        }
        .tint(.pink)
        // 点卡片 -> store.playURL 被赋值 -> 全屏起 VLC
        .fullScreenCover(item: Binding(
            get: { store.playURL.map { PlayBox(url: $0, title: store.playingTitle ?? "") } },
            set: { if $0 == nil { store.stopPlay() } }
        )) { box in
            VLCPlayerScreen(url: box.url, title: box.title) {
                store.stopPlay()
            }
            .environmentObject(store)
        }
        .overlay {
            if store.playingTitle != nil && store.playURL == nil {
                ZStack {
                    Color.black.opacity(0.78).ignoresSafeArea()
                    VStack(spacing: 14) {
                        ProgressView().tint(.white)
                        Text(store.playingTitle ?? "")
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                        Button("取消") { store.stopPlay() }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }
        .alert("打不开", isPresented: Binding(
            get: { store.errorText != nil },
            set: { if !$0 { store.errorText = nil } })) {
            Button("知道了", role: .cancel) { store.errorText = nil }
        } message: {
            Text(store.errorText ?? "")
        }
    }
}

// MARK: - fullScreenCover 的 Identifiable 包装

struct PlayBox: Identifiable {
    let url: URL
    let title: String
    var id: String { url.absoluteString + title }
}
