//
//  TxinApp.swift
//  Txin （iOS）
//
//  iOS 版入口。核心协议来自 Core/（与 macOS 版同一套算法）。
//

import SwiftUI

@main
struct TxinIOSApp: App {
    @StateObject private var store = AppStore()

    init() {
        // 深色外观，配合内容浏览
        UINavigationBar.appearance().largeTitleTextAttributes =
            [.foregroundColor: UIColor.white]
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .task { await store.bootstrap() }
        }
    }
}
