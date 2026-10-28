// swift-tools-version:5.9
// Txin —— 糖心 (tangxgw.com / txinweb1.com) 原生客户端
// 产物:
//   TxinKit  —— 协议核心库（加解密 / 会话 / API / HLS 下载）
//   txin     —— 命令行工具（selftest / call / dl / search）
//   TxinApp  —— SwiftUI 桌面 App，scripts/build-app.sh 组装成 Txin.app
import PackageDescription

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
            path: "Sources/TxinKit"
        ),
        .executableTarget(
            name: "txin",
            dependencies: ["TxinKit"],
            path: "Sources/txin"
        ),
        .executableTarget(
            name: "TxinApp",
            dependencies: ["TxinKit"],
            path: "Sources/TxinApp"
        ),
    ]
)
