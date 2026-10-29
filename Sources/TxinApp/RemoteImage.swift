//
//  RemoteImage.swift
//  TxinApp （macOS）
//

import SwiftUI
import AppKit
import TxinKit

final class ImageCache {
    static let shared = ImageCache()
    private let mem = NSCache<NSString, NSImage>()

    private init() {
        mem.countLimit = 300
        mem.totalCostLimit = 120 * 1024 * 1024
    }

    func get(_ key: String) -> NSImage? { mem.object(forKey: key as NSString) }

    func put(_ key: String, _ img: NSImage) {
        let cost = Int(img.size.width * img.size.height * 4)
        mem.setObject(img, forKey: key as NSString, cost: cost)
    }

    func clear() { mem.removeAllObjects() }
}

struct RemoteImage<Placeholder: View>: View {
    let url: String?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var failed = false
    @State private var loading = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                placeholder()
            } else {
                ZStack {
                    Color.secondary.opacity(0.12)
                    if loading { ProgressView().controlSize(.small) }
                }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, !url.isEmpty else { failed = true; return }
        let full = TxinCDN.rewrite(url) ?? url
        guard let u = URL(string: full) else { failed = true; return }

        if let hit = ImageCache.shared.get(full) {
            image = hit
            return
        }

        loading = true
        defer { loading = false }

        for attempt in 0..<2 {
            do {
                var req = URLRequest(url: u)
                req.timeoutInterval = attempt == 0 ? 20 : 35
                req.setValue(TxinClient.userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue(TxinEndpoint.base, forHTTPHeaderField: "Referer")

                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 { continue }

                let decoded = TxinImage.decodeIfNeeded([UInt8](data), url: url)
                if let img = NSImage(data: Data(decoded)) {
                    ImageCache.shared.put(full, img)
                    image = img
                    return
                }
            } catch {
                continue
            }
        }
        failed = true
    }
}

struct ImagePlaceholder: View {
    var icon: String = "photo"
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }
}
