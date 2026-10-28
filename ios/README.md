# 糖心 iOS 客户端（.ipa）

用同一套协议代码，做的 iOS 原生 App。

---

## 先说清楚：ipa 和 macOS 的 .app 不是一回事

上一步 macOS 版能"零编译"出包，是因为 **macOS 允许 shell 脚本当 App 入口**。iOS 不行：

| | macOS | iOS |
|---|---|---|
| 可执行入口 | Mach-O **或** 任意带 shebang 的脚本 | **必须**是 ARM64 Mach-O |
| 签名 | ad-hoc（`codesign -s -`）即可 | 必须有效签名，未签名的装不上 |
| 运行时 | bash / zsh 都在 | 没有 shell |
| 能不能在 Windows 上产 | ✅ 能（组装目录 + 写权限位） | ❌ 不能（必须有 iOS SDK 编译 + 签名） |

**所以 ipa 只能在 macOS + Xcode 上产出。** 这是 Apple 的硬性约束，没有变通。

---

## 你手上现在有什么

**完整的、已校验的 Xcode 工程**（Windows 上生成，Mac 上直接打开就能编译）：

```
ios/
├── TxinApp.xcodeproj/            project.pbxproj（16.6 KB）+ 共享 scheme
│   └── xcshareddata/xcschemes/Txin.xcscheme
├── TxinApp/
│   ├── App/                      TxinApp.swift · AppStore.swift
│   ├── Core/                     协议核心 7 个文件（与 macOS 版同一套算法）
│   ├── Features/                 RootView · HomeView · DetailView · DownloadsView · SettingsView
│   └── Resources/                Info.plist · Assets.xcassets（含 1024 图标）
├── ExportOptions.plist           导出配置
└── README.md
```

工程状态（`gen_ios_xcodeproj.py --verify` 实测）：

```
[verify] OK
  object 数            : 49
  target               : Txin (com.apple.product-type.application)
  swift 全部进入 Sources: 14/14
  PRODUCT_BUNDLE_IDENTIFIER: com.txin.ios（Debug/Release 共 2 份配置）

关键 build settings:
  SDKROOT                    = iphoneos
  IPHONEOS_DEPLOYMENT_TARGET = 16.0
  TARGETED_DEVICE_FAMILY     = "1,2"      (iPhone + iPad)
  SWIFT_VERSION              = 5.0
  GENERATE_INFOPLIST_FILE    = NO
  INFOPLIST_FILE             = TxinApp/Resources/Info.plist
```

14 个 Swift 文件 / 2246 行，结构自查通过（括号平衡、跨 module 可见性、AppKit/AVKit import、`List(selection:)` Optional）。

---

## 在 Mac 上打 ipa

```bash
cd apple
chmod +x scripts/build-ipa.sh

# ① 未签名（给自签工具用）
./scripts/build-ipa.sh --unsigned
#   → build/Txin-1.0.0-unsigned.ipa

# ② 用开发者账号签名
./scripts/build-ipa.sh --signed --team ABCDE12345
#   → build/Txin-1.0.0.ipa（可直接装）

# ③ 直接推到连着的数据线设备
./scripts/build-ipa.sh --device --team ABCDE12345
```

脚本会自动：
1. 检查 `xcodebuild`（必须是 Xcode，不是 CLT）
2. 用 `gen_ios_xcodeproj.py` 重新扫一遍源文件，保证新加的 `.swift` 进了 Sources Build Phase
3. `xcodebuild clean build`（未签名模式关掉所有签名）
4. **校验产物是真 Mach-O 且 arm64** —— `file` + `lipo -info` 双重断言，不是就中止
5. 组 `Payload/Txin.app` → zip → 改名 `.ipa`

签名模式走 `archive` + `exportArchive`，`ExportOptions.plist` 里默认 `method=development`。

---

## 三种装法（未签名 ipa）

| 方式 | 前提 | 有效期 |
|---|---|---|
| **TrollStore** | iOS 14.0 – 16.6.1（部分版本），用漏洞永久签名 | 永久 |
| **Sideloadly / AltStore** | 任意 iOS + 一台电脑 + 免费 Apple ID | 7 天，到期重签 |
| **Xcode 直装** | Mac + 登录 Apple ID | 7 天 |

付费开发者账号（$99/年）可以出 1 年有效的 ad-hoc / App Store 包。

---

## App 里有什么

- **首页**：视频网格（VIP 角标、播放量、时长），下拉刷新，翻页
- **艺人**：艺人卡片 + 粉丝数
- **详情**：封面、AVKit 直接播 m3u8（秒开，不落地）、「下载并解密」
- **下载**：进度条、断点续传、**分享/导出**（`ShareLink`，可存到「文件」App 或发出去）
- **我的**：会话信息、CDN 探测、一键复制

**iOS 的下载文件在沙盒里**，所以 `Info.plist` 开了：

```xml
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

这样「文件」App →「我的 iPhone」→「Txin」→ `txin/<作品ID>/` 里能直接看到 `.ts`，长按可以移到 iCloud 或分享出来。

---

## 已知限制

| 项 | 说明 |
|---|---|
| `.ts` 不能在 iOS 上转 mp4 | 没有 ffmpeg。要在电脑上转：`ffmpeg -i x.ts -c copy x.mp4` |
| 后台下载会被挂起 | iOS 限制，切到后台可能被系统暂停，回前台继续 |
| 首次运行要信任 | 自签 App 需要在「设置 → 通用 → VPN与设备管理」里信任开发者 |
| 没有上架 | 侧载使用，不进 App Store |

---

## GitHub Actions（可选）

`.github/workflows/build-ipa.yml` 能在 `macos-14` runner 上出未签名 ipa——runner 自带 Xcode，这是**唯一不依赖你本机 Mac**的 ipa 产出方式（但仓库仍需你的 GitHub 账号）。

配了证书相关的 secrets 会顺带出签名版。

---

## 在 Windows 上能验什么

```powershell
cd apple
python tools/gen_ios_xcodeproj.py --verify   # 工程结构 + 49 对象 + 14/14 源文件
node scripts/lint_swift.mjs ios              # 14 文件 2246 行，无结构性问题
python -c "import yaml;yaml.safe_load(open('.github/workflows/build-ipa.yml'))"   # workflow 语法
```

CI 上真正新增的只有 Xcode 编译器。所以本地这些绿了，Mac 上剩下的就是编译期类型/API 问题。
