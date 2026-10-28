//
//  DownloadsView.swift
//  Txin （iOS）
//

import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingDelete: DownloadJob?

    var body: some View {
        NavigationStack {
            List {
                if store.jobs.isEmpty {
                    ContentUnavailableViewCompat(
                        title: "还没有下载",
                        systemImage: "arrow.down.circle",
                        hint: "在首页点开作品，按「下载并解密」")
                }

                ForEach(store.jobs) { job in
                    DownloadRow(job: job)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = job
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清理已完成") { store.clearFinished() }
                        .disabled(store.jobs.isEmpty)
                }
            }
            .confirmationDialog("删除这个下载？",
                                isPresented: Binding(
                                    get: { pendingDelete != nil },
                                    set: { if !$0 { pendingDelete = nil } }),
                                presenting: pendingDelete) { job in
                Button("删除文件", role: .destructive) {
                    store.deleteDownload(job)
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: { job in
                Text(job.title)
            }
        }
    }
}

struct DownloadRow: View {
    let job: DownloadJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(job.title).font(.footnote.bold()).lineLimit(1)
                Spacer()
                Text(job.phase.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
            }

            if job.total > 0 && job.phase == .downloading {
                ProgressView(value: job.fraction)
                    .tint(.pink)
            }

            HStack(spacing: 10) {
                if job.total > 0 {
                    Text("\(job.done)/\(job.total)")
                }
                Text(job.sizeText)
                if !job.note.isEmpty {
                    Text(job.note).lineLimit(1)
                }
                Spacer()
                if let url = job.fileURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var color: Color {
        switch job.phase {
        case .done:   return .green
        case .failed: return .red
        default:      return .secondary
        }
    }
}

/// iOS 16 没有 ContentUnavailableView（那个是 17），这里补一个等价物
struct ContentUnavailableViewCompat: View {
    let title: String
    let systemImage: String
    let hint: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text(title).font(.callout)
            Text(hint).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }
}
