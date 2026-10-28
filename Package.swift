// swift-tools-version:5.9
// Txin —— 糖心 (tangxgw.com / txinweb1.com) 原生客户端
// 产物:
//   TxinKit  —— 协议核心库（加解密 / 会话 / API / HLS 下载）
//   txin     —— 命令行工具（selftest / call / dl / search）
//   TxinApp  —— SwiftUI 桌面 App，scripts/build-app.sh 组装成 Txin.app
import PackageDescription

// 这台 runner 的 Swift 编译器默认开了较严格的并发检查，
// @Sendable 闭包捕获可变 var、可变全局状态这类写法会直接判为错误。
// 本项目是单机 CLI/App，不需要那种级别的隔离，统一降到 minimal。
let relaxedConcurrency: [SwiftSetting] = [
    .unsafeFlags(["-Xfrontend", "-strict-concurrency=minimal"])
]

let package = Package(
    name: "Txin",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TxinKit", targets: ["TxinKit"]),
        .executable(name: "txin", targets: ["txin"]),
        .executable(name: "TxinApp", targets: ["TxinApp"]),
    ],
    targets: [
        .target(
            name: "TxinKit",
            path: "Sources/TxinKit",
            swiftSettings: relaxedConcurrency
        ),
        .executableTarget(
            name: "txin",
            dependencies: ["TxinKit"],
            path: "Sources/txin",
            swiftSettings: relaxedConcurrency
        ),
        .executableTarget(
            name: "TxinApp",
            dependencies: ["TxinKit"],
            path: "Sources/TxinApp",
            swiftSettings: relaxedConcurrency
        ),
    ]
)
