//
//  CLI.swift
//  txin
//
//  命令行入口。设计原则：任何一步都能单独验证，出问题一眼看出是协议、网络还是 CDN。
//

import Foundation
import TxinKit

@main
struct TxinCLI {

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else {
            printHelp()
            exit(0)
        }
        args.removeFirst()

        do {
            switch cmd {
            case "selftest":   try runSelfTest(args)
            case "info":       try await runInfo(args)
            case "call":       try await runCall(args)
            case "list":       try await runList(args)
            case "detail":     try await runDetail(args)
            case "dl":         try await runDownload(args)
            case "cdn":        try await runCDN(args)
            case "-h", "--help", "help": printHelp()
            default:
                fputs("未知命令: \(cmd)\n", stderr)
                printHelp()
                exit(1)
            }
        } catch {
            fputs("✗ \(error)\n", stderr)
            exit(1)
        }
    }

    static func printHelp() {
        print("""
        txin —— 糖心 (tangxgw.com / txinweb1.com) 命令行客户端

        用法:
          txin selftest [--vectors <json>]      协议金标校验（首次务必跑这个）
          txin info                             显示当前会话（user_id / token / VIP / 镜像）
          txin cdn                              探测 CDN，报告是否被劫持
          txin call <path> [json]               调任意接口，如: txin call /system/home '{}'
          txin list [page] [cat_id]             视频列表
          txin detail <id>                      视频详情（含 m3u8）
          txin dl <id> [-o <目录>] [-l <线路>]  下载并解密合并为 .ts

        示例:
          txin selftest
          txin list 1 1
          txin detail 309770
          txin dl 309770 -o ~/Movies/txin
        """)
    }

    // MARK: - selftest

    static func runSelfTest(_ args: [String]) throws {
        let path = value(after: "--vectors", in: args)
            ?? findVectors()
        guard let path else {
            fputs("找不到 test-vectors.json，用 --vectors 指定路径\n", stderr)
            exit(2)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        print("向量文件: \(path)")
        let r = TxinSelfTest.run(vectorsJSON: data)
        print("通过: \(r.passed) 项")
        if r.ok {
            print("✓ 协议实现与参考实现逐字节一致")
        } else {
            for f in r.failed { print("✗ \(f)") }
            exit(3)
        }
    }

    static func findVectors() -> String? {
        let candidates = [
            "test-vectors.json",
            "apple/test-vectors.json",
            FileManager.default.currentDirectoryPath + "/test-vectors.json",
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return c
        }
        // 从可执行文件往上找三层
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<4 {
            let p = dir.appendingPathComponent("test-vectors.json").path
            if FileManager.default.fileExists(atPath: p) { return p }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - info

    static func runInfo(_ args: [String]) async throws {
        let client = TxinClient()
        print("建立会话…")
        try await client.bootstrap()
        await TxinCDN.autoSelectMirror()

        let p = await client.profile
        print("""
        ── 会话 ──
        user_id  : \(p?.user_id ?? "-")
        username : \(p?.username ?? "-")
        nickname : \(p?.nickname ?? "-")
        is_vip   : \(p?.is_vip ?? "-")
        token    : \(p?.token ?? "-")
        deviceId : \(await client.deviceId)
        ── 镜像 ──
        active   : \(TxinCDN.activeMirrors.isEmpty ? "国内 whk.srslpoh.cn（直连）" : "CloudFront 镜像（国内域名被劫持）")
        """)

        let r = try await client.systemInfo()
        if let info = r.data {
            print("站点: \(info.header?.site_title ?? "-")")
            print("img_key: \(info.img_key ?? "-")")
            print("上传接口: \(info.upload_image_url?.prefix(72) ?? "-")…")
            print("镜像域名: \((info.domain_statistic ?? []).map(\.domain).joined(separator: ", "))")
        }
    }

    // MARK: - cdn

    static func runCDN(_ args: [String]) async throws {
        let ok = await TxinCDN.probeDomestic()
        print("国内域名 whk.srslpoh.cn : \(ok ? "✓ 可用" : "✗ 被劫持/不可达 → 自动切 CloudFront")")
        await TxinCDN.autoSelectMirror()
        print("生效镜像: \(TxinCDN.activeMirrors.isEmpty ? "直连" : "CloudFront")")
    }

    // MARK: - call

    static func runCall(_ args: [String]) async throws {
        guard let path = args.first else {
            fputs("用法: txin call <path> [json]\n", stderr)
            exit(1)
        }
        var payload: Any = [String: Any]()
        if args.count > 1, let d = args[1].data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) {
            payload = obj
        }
        let client = TxinClient()
        try await client.bootstrap()
        await TxinCDN.autoSelectMirror()
        let out = try await client.callRaw(path, payload: payload)
        if let s = String(data: out, encoding: .utf8) {
            print(s)
        } else {
            print("<\(out.count) 字节二进制>")
        }
    }

    // MARK: - list

    static func runList(_ args: [String]) async throws {
        let page = Int(args.first ?? "1") ?? 1
        let cat = args.count > 1 ? args[1] : "1"
        let client = TxinClient()
        try await client.bootstrap()
        await TxinCDN.autoSelectMirror()
        let r = try await client.movieHome(catId: cat, page: page)
        guard let blocks = r.data?.data else {
            print("无数据 status=\(r.status ?? "-")")
            return
        }
        for block in blocks {
            print("\n【\(block.name ?? "-")】\(block.intro ?? "")")
            for m in (block.items ?? []) {
                let flag = m.isPaid ? "VIP" : "   "
                print(String(format: "  %@ %-8@  %@  时长%@", flag, m.id as NSString,
                             (m.name ?? "-") as NSString, (m.duration ?? "-") as NSString))
            }
        }
    }

    // MARK: - detail

    static func runDetail(_ args: [String]) async throws {
        guard let id = args.first else {
            fputs("用法: txin detail <id>\n", stderr)
            exit(1)
        }
        let client = TxinClient()
        try await client.bootstrap()
        await TxinCDN.autoSelectMirror()
        let r = try await client.movieDetail(id: id)
        guard let d = r.data else {
            print("无数据: \(r.error ?? "-")")
            return
        }
        print("""
        标题   : \(d.name ?? "-")
        分类   : \(d.category?.name ?? "-")
        付费   : \(d.pay_type ?? "-") / \(d.layer_type ?? "-")
        时长   : \(d.duration ?? "-")
        播放   : \(d.click ?? "-")   收藏: \(d.favorite ?? "-")
        封面   : \(d.coverURL?.absoluteString ?? "-")
        ── 线路 ──
        """)
        for l in (d.play_links ?? []) {
            print("  \(l.name ?? "-")  \(l.m3u8_url ?? "-")")
        }
    }

    // MARK: - dl

    static func runDownload(_ args: [String]) async throws {
        guard let id = args.first else {
            fputs("用法: txin dl <id> [-o 目录]\n", stderr)
            exit(1)
        }
        let outDir = value(after: "-o", in: args)
            ?? (FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Movies/txin").path)

        let client = TxinClient()
        print("建立会话…")
        try await client.bootstrap()
        await TxinCDN.autoSelectMirror()

        let r = try await client.movieDetail(id: id)
        guard let d = r.data, let link = d.bestLink, let m3u8 = link.m3u8_url else {
            fputs("拿不到播放地址: \(r.error ?? "-")\n", stderr)
            exit(2)
        }
        print("""
        标题 : \(d.name ?? "-")
        付费 : \(d.pay_type ?? "-") / \(d.layer_type ?? "-")  （后端不鉴权，游客可取）
        线路 : \(link.name ?? "-")
        m3u8 : \(m3u8)
        """)

        let full = m3u8.hasPrefix("http") ? m3u8 : TxinClient.defaultHost + m3u8
        let dl = HLSDownloader()
        print("拉取播放列表…")
        let playlist = try await dl.fetchPlaylist(m3u8: full, referer: TxinClient.defaultHost + "/")
        print("分片 \(playlist.segments.count)  加密 \(playlist.key != nil ? playlist.key!.method : "无")  IV \(playlist.key?.iv.map { TxinCrypto.bytesToHex($0) } ?? "-")")

        let dir = URL(fileURLWithPath: outDir).appendingPathComponent(id)
        var lastPct = -1
        let merged = try await dl.download(playlist, to: dir, referer: TxinClient.defaultHost + "/",
            onProgress: { p in
                let pct = Int(p.fraction * 100)
                if pct != lastPct {
                    lastPct = pct
                    let mb = Double(p.bytes) / 1_048_576
                    FileHandle.standardError.write(Data("\r下载 \(p.done)/\(p.total)  \(pct)%  \(String(format: "%.1f", mb)) MB".utf8))
                }
            },
            onState: { s in
                FileHandle.standardError.write(Data("\r\(s)                                \n".utf8))
            })

        // 改名成 <id>_<标题>.ts 更友好
        let safeTitle = (d.name ?? id)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let finalURL = dir.appendingPathComponent("\(id)_\(safeTitle).ts")
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: merged, to: finalURL)

        let size = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        print("\n✓ \(finalURL.path)")
        print("  \(String(format: "%.2f", Double(size) / 1_048_576)) MB")
        print("  转 mp4: ffmpeg -i \"\(finalURL.path)\" -c copy \"\(finalURL.deletingPathExtension().path).mp4\"")
    }

    // MARK: - 工具

    static func value(after flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}
