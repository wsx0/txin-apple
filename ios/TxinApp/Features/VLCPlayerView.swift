//
//  VLCPlayerView.swift
//  Txin （iOS）
//
//  为什么用 VLCKit 而不是 AVPlayer：
//
//   糖心的视频是「每个 TS 分片各带一套 PAT/PMT」的 HLS。拼接后的媒体里
//   同一组 PID（0x100 视频 / 0x101 音频）会出现多套 program 声明。
//   AVFoundation 只认第一个 program —— 表现就是「播几秒就停」，无论怎么调
//   preferredForwardBufferDuration、AVAssetResourceLoaderDelegate 都没用。
//
//   mpv / libVLC 这类 FFmpeg 内核会按 PES 时间戳重新组织，不受影响。
//   暮色那个 App 用的就是 libmpv.so，同样思路。
//
//   VLCKit 还顺带解决了 AES-128 分片解密 —— 那是它 HLS 实现的标配能力，
//   我们不用再自己 CCCrypt，也就不会再有 IV 指针那一类问题。
//

import SwiftUI
import MobileVLCKit

/// VLC 的渲染视图。用 `drawable` 挂到 VLCMediaPlayer 上。
struct VLCVideoSurface: UIViewRepresentable {
    final class SurfaceView: UIView {
        override class var layerClass: AnyClass { CALayer.self }
    }

    func makeUIView(context: Context) -> SurfaceView {
        let v = SurfaceView()
        v.backgroundColor = .black
        v.contentMode = .scaleAspectFit
        return v
    }

    func updateUIView(_ uiView: SurfaceView, context: Context) {}
}

/// 全屏 VLC 播放器
struct VLCPlayerScreen: View {
    let url: URL
    let title: String
    let onClose: () -> Void

    @State private var player = VLCMediaPlayer()
    @State private var surface: VLCVideoSurface.SurfaceView?
    @State private var stateText = "缓冲中…"
    @State private var isPlaying = false
    @State private var progress: Float = 0
    @State private var duration: Int32 = 0
    @State private var time: Int32 = 0
    @State private var showControls = true
    @State private var observer: Timer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 画面
            VLCSurfaceHolder(surface: $surface)
                .ignoresSafeArea()

            // 简单的控制层
            if showControls {
                VStack {
                    HStack {
                        Button { close() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.black.opacity(0.4), in: Circle())
                        }
                        Spacer()
                        Text(title)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Color.clear.frame(width: 41, height: 41)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    Spacer()

                    // 进度
                    VStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { Double(progress) },
                            set: { newValue in
                                progress = Float(newValue)
                                let target = Int32(Double(duration) * Double(newValue))
                                player.time = VLCTime(int: target)
                            }), in: 0...1)
                            .tint(.pink)

                        HStack {
                            Text(fmt(time))
                            Spacer()
                            Text(stateText).lineLimit(1)
                            Spacer()
                            Text(fmt(duration))
                        }
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))

                        HStack(spacing: 36) {
                            Button { player.jumpBackward(10) } label: {
                                Image(systemName: "gobackward.10").font(.title2)
                            }
                            Button { togglePlay() } label: {
                                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 34))
                            }
                            Button { player.jumpForward(10) } label: {
                                Image(systemName: "goforward.10").font(.title2)
                            }
                        }
                        .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 24)
                }
                .background(
                    LinearGradient(colors: [.black.opacity(0.55), .clear, .black.opacity(0.65)],
                                   startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                )
            }
        }
        .statusBarHidden()
        .onTapGesture { showControls.toggle() }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    // MARK: - 控制

    private func start() {
        let media = VLCMedia(url: url)
        // 缓冲区给足，手机网络波动时不至于立刻断
        media.addOption(":network-caching=4000")
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        // 让 FFmpeg 自己处理 HLS 的 AES-128
        media.addOption(":http-referrer=" + TxinEndpoint.base)
        media.addOption(":http-user-agent=" + TxinClient.userAgent)

        player.media = media
        player.delegate = VLCDelegate.shared
        VLCDelegate.shared.onState = { s in
            DispatchQueue.main.async {
                stateText = s
                isPlaying = (player.isPlaying)
            }
        }
        player.drawable = surface
        player.play()

        observer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            guard let media = player.media else { return }
            let total = media.length.intValue
            duration = total
            let cur = player.time.intValue
            time = cur
            if total > 0 {
                progress = min(1, max(0, Float(Double(cur) / Double(total))))
            }
            isPlaying = player.isPlaying
        }
    }

    private func stop() {
        observer?.invalidate()
        observer = nil
        player.stop()
    }

    private func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    private func close() {
        stop()
        onClose()
    }

    private func fmt(_ ms: Int32) -> String {
        let s = max(0, Int(ms) / 1000)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - 把 VLC 的 drawable 绑到 SwiftUI 视图

struct VLCSurfaceHolder: UIViewRepresentable {
    @Binding var surface: VLCVideoSurface.SurfaceView?

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let v = VLCVideoSurface.SurfaceView()
        v.backgroundColor = .black
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            v.topAnchor.constraint(equalTo: container.topAnchor),
            v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { surface = v }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - 状态代理

final class VLCDelegate: NSObject, VLCMediaPlayerDelegate {
    static let shared = VLCDelegate()
    var onState: ((String) -> Void)?

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard let p = aNotification.object as? VLCMediaPlayer else { return }
        let text: String
        switch p.state {
        case .opening:      text = "打开中…"
        case .buffering:    text = "缓冲中…"
        case .playing:      text = "播放中"
        case .paused:       text = "已暂停"
        case .stopped:      text = "已停止"
        case .ended:        text = "播放结束"
        case .error:        text = "出错了"
        case .esAdded:      text = "解码器就绪"
        default:            text = ""
        }
        onState?(text)
    }
}
