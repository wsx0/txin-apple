//
//  SettingsView.swift
//  Txin （iOS）
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var copied = false

    var body: some View {
        NavigationStack {
            List {
                Section("会话") {
                    row("user_id", store.profile?.user_id)
                    row("nickname", store.profile?.nickname)
                    row("is_vip", store.profile?.is_vip)
                    row("token", store.profile?.token)
                    row("deviceId", store.deviceId)
                }

                Section("网络") {
                    HStack {
                        Text("国内 CDN")
                        Spacer()
                        Text(statusText)
                            .foregroundStyle(statusColor)
                            .font(.footnote)
                    }
                    Button("重新探测") {
                        Task { await store.probeCDN() }
                    }
                }

                Section("播放内核") {
                    HStack {
                        Text("引擎")
                        Spacer()
                        Text("VLCKit 3.7.4 (libVLC + FFmpeg)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("""
                    糖心的视频是「每个分片各带一套 PAT/PMT」的 HLS，\
                    拼接后同一组 PID 会出现多套 program 声明。\
                    AVFoundation 只认第一个 program（表现：播几秒就停），\
                    FFmpeg 按 PES 时间戳重组，不受影响。
                    """)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("站 点") {
                    row("标题", store.systemInfo?.header?.site_title)
                    row("img_key", store.systemInfo?.img_key)
                }

                Section {
                    Button {
                        UIPasteboard.general.string = store.sessionSummary
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "已复制" : "复制会话信息",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                }

                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .foregroundStyle(.secondary)
                    }
                    Text("协议：AES-256-CBC + HMAC-SHA256 请求加密；图片为 AES-128-ECB 加密的 .bnc；视频 HLS AES-128 交给 VLCKit 自行解密。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
        }
    }

    private var statusText: String {
        guard let ok = store.cdnDomesticOK else { return "未探测" }
        return ok ? "可用" : "被劫持 → 走镜像"
    }

    private var statusColor: Color {
        guard let ok = store.cdnDomesticOK else { return .secondary }
        return ok ? .green : .orange
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String?) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text((v?.isEmpty == false) ? v! : "-")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
