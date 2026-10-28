//
//  RootView.swift
//  Txin （iOS）
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

            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle.fill") }
                .badge(activeCount)
                .tag(2)

            SettingsView()
                .tabItem { Label("我的", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .tint(.pink)
        .alert("出错了", isPresented: Binding(
            get: { store.errorText != nil },
            set: { if !$0 { store.errorText = nil } })) {
            Button("知道了", role: .cancel) { store.errorText = nil }
        } message: {
            Text(store.errorText ?? "")
        }
    }

    private var activeCount: Int {
        store.jobs.filter { $0.phase != .done && $0.phase != .failed }.count
    }
}
