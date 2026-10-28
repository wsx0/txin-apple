//
//  SettingsView.swift
//  TxinApp
//

import SwiftUI
import AppKit
import TxinKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("downloadDir") private var downloadDir: String = "~/Movies/txin"
    @AppStorage("concurrency") private var concurrency: Int = 6
    @AppStorage("preferCloudFront") private var preferCloudFront: Bool = true

    var body: some View {
        TabView {
            general.tabItem { Label("通用", systemImage: "gearshape") }
            session.tabItem { Label("会话", systemImage: "person.crop.circle") }
            about.tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
    }

    private var general: some View {
        Form {
            Section("下载") {
                HStack {
                    TextField("保存目录", text: $downloadDir)
                    Button("选…") { pickFolder() }
                }
                Stepper("并发分片：\(concurrency)", value: $concurrency, in: 1...16)
            }
            Section("网络") {
                Toggle("优先使用 CloudFront 镜像（国内域名常被劫持）", isOn: $preferCloudFront)
                HStack {
                    Button("重新探测 CDN") { Task { await store.probeCDN() } }
                    Spacer()
                    Text(store.cdnDomesticOK == nil ? "未探测"
                         : (store.cdnDomesticOK! ? "国内可用" : "已切镜像"))
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var session: some View {
        Form {
            Section("当前会话") {
                row("user_id", store.profile?.user_id)
                row("username", store.profile?.username)
                row("nickname", store.profile?.nickname)
                row("is_vip", store.profile?.is_vip)
                row("token", store.profile?.token)
                row("deviceId", store.deviceId)
            }
            Section("站点") {
                row("标题", store.systemInfo?.header?.site_title)
                row("img_key", store.systemInfo?.img_key)
            }
            Section {
                Button("复制全部会话信息") {
                    copyToPasteboard(store.sessionSummary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("糖心 macOS 客户端").font(.title3.bold())
            Text("协议版本 2026-10 · Swift/SwiftPM 构建")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("AES-256-CBC + HMAC-SHA256 请求加密，HLS AES-128 分片解密")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(24)
    }

    @ViewBuilder
    private func row(_ k: String, _ v: String?) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v?.isEmpty == false ? v! : "-")
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            downloadDir = url.path
        }
    }
}
