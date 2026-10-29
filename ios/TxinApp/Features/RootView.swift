//
//  RootView.swift
//  Txin （iOS）
//
//  极简形态：首页点卡片 -> 直接全屏播。没有详情页、没有线路选择、没有下载流程。
//

import SwiftUI
import AVKit

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
        // 点卡片 -> store.playerItem 被赋值 -> 这里直接全屏起播
        .fullScreenCover(item: Binding(
            get: { store.playerItem.map { PlayBox(item: $0, title: store.playingTitle ?? "") } },
            set: { if $0 == nil { store.stopPlay() } }
        )) { box in
            FullPlayer(item: box.item, title: box.title) {
                store.stopPlay()
            }
        }
        .overlay {
            if store.playingTitle != nil && store.playerItem == nil {
                ZStack {
                    Color.black.opacity(0.75).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().tint(.white)
                        Text(store.playingTitle ?? "")
                            .font(.footnote)
                            .foregroundStyle(.white)
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
    let item: AVPlayerItem
    let title: String
    var id: ObjectIdentifier { ObjectIdentifier(item) }
}

// MARK: - 全屏播放器

struct FullPlayer: UIViewControllerRepresentable {
    let item: AVPlayerItem
    let title: String
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        vc.player = player
        vc.showsPlaybackControls = true
        vc.allowsPictureInPicturePlayback = true
        vc.entersFullScreenWhenPlaybackBegins = false

        // 卡住时给一句提示，别让用户以为死了
        context.coordinator.observe(item, vc: vc)

        player.play()
        context.coordinator.player = player
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: AVPlayer?
        private var tokens: [NSObjectProtocol] = []

        func observe(_ item: AVPlayerItem, vc: AVPlayerViewController) {
            let c = NotificationCenter.default
            tokens.append(c.addObserver(forName: AVPlayerItem.playbackStalledNotification,
                                        object: item, queue: .main) { _ in
                vc.player?.play()      // 卡住就再推一把
            })
            tokens.append(c.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime,
                                        object: item, queue: .main) { n in
                if let e = n.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error {
                    print("[txin] 播放失败: \(e)")
                }
            })
        }

        deinit {
            tokens.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
