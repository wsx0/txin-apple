//
//  TxinApp.swift
//  TxinApp
//
//  macOS 桌面客户端入口。SwiftPM 产物 + scripts/build-app.sh 组装成 Txin.app。
//

import SwiftUI
import AppKit
import TxinKit

@main
struct TxinAppEntry: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup("糖心") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 660)
                .task { await store.bootstrap() }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("操作") {
                Button("刷新列表") { Task { await store.loadHome() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("探测 CDN") { Task { await store.probeCDN() } }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Button("复制当前会话") { copyToPasteboard(store.sessionSummary) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

func copyToPasteboard(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
}
