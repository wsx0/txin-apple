# 没有 Mac，怎么拿到 Txin.app

本文只讲 B 路线：**Windows 上写代码 → GitHub Actions 的 macOS 机器编译 → 下载 .app**。

---

## 0. 你需要什么

| 项 | 说明 | 检查 |
|---|---|---|
| GitHub 账号 | 免费版够用 | — |
| git | 推代码 | `git --version` |
| 一台 Mac | **只在最后打开 .app 时需要** | 见下方「绕不开的一条」 |

---

## 1. 一键推

在 `apple/` 目录里：

```powershell
# 已经建好仓库的话
.\push-to-github.ps1 -Remote https://github.com/<你>/txin-mac.git

# 装了 GitHub CLI（winget install GitHub.cli; gh auth login）可以连仓库一起建
.\push-to-github.ps1 -Create -RepoName txin-mac
```

脚本会检查工具链 → `git init` → 提交 → 建远端 → 推送，最后打出 Actions 地址。

不想用脚本，手搓也行：

```bash
cd apple
git init -b main
git add -A
git commit -m "feat: 糖心 macOS 客户端"
git remote add origin https://github.com/<你>/txin-mac.git
git push -u origin main
```

> **仓库根放什么都能跑。** workflow 会自己判断：根目录有 `Package.swift` 就用根目录，否则找 `apple/Package.swift`。所以整包 `txinweb1-recon/` 推上去也一样能出包。

---

## 2. 触发构建

推上去后自动跑。也可以手动：

```
仓库页 → Actions → 左栏「Build macOS App」→ 右上「Run workflow」→ 勾 make_dmg → 绿色按钮
```

### 流水线在做的事

```
checkout
  └─ 定位工程根（自适应 apple/ 或 仓库根）
       └─ 编译 CLI
            └─ ★ 协议金标自检   ← 不过就整体失败，不会产出坏 App
                 └─ 结构自查（lint，失败不阻断）
                      └─ build-app.sh --dmg（编译 App + 组装 bundle + ad-hoc 签名）
                           └─ 产物校验（codesign -v / lipo -info）
                                └─ 冒烟测试（CLI 直连真实接口，允许失败）
                                     └─ 上传 Artifacts
```

runner 在境外，`whk.srslpoh.cn` 没被劫持，冒烟测试大概率能直接跑通——顺便帮你验证端到端。

### 耗时与额度

| 项 | 值 |
|---|---|
| 单次耗时 | 3~6 分钟（有缓存后 2~3 分钟） |
| 公开仓库 | 免费，不占额度 |
| 私有仓库 | macOS runner 按 **10 倍**计费；免费额度 2000 分钟/月 → 约 200 分钟 macOS |

---

## 3. 下载产物

```
那次 run 的页面 → 底部 Artifacts → Txin-macos-<N>.zip
```

zip 里是：

```
Txin.app/                     ← 拖进 /Applications 就能双击
Txin-1.0.0.dmg                ← 勾了 make_dmg 才有
```

---

## 4. ⚠️ 绕不开的一条：解压必须在 Mac 上做

`.app` 里的可执行文件带 Unix 权限位（`0755`）。GitHub 的 artifact 是 zip，**在 macOS 上解压会保留权限**；但在 Windows 上用资源管理器解压会丢，再拷到 Mac 就变成「打不开，因为无法验证开发者」或者干脆闪退。

所以：

| 做法 | 结果 |
|---|---|
| 在 Mac 浏览器直接下 zip → Finder 双击解压 | ✅ 权限正常 |
| Windows 下 zip，**原样拷贝 zip 文件**到 Mac 再解 | ✅ 权限正常 |
| Windows 上解开，再把 `Txin.app` 拷到 Mac | ❌ 权限丢失 |

万一已经踩了，Mac 上补一句就行：

```bash
chmod +x /Applications/Txin.app/Contents/MacOS/Txin
xattr -cr /Applications/Txin.app
codesign --force --deep --sign - /Applications/Txin.app
```

---

## 5. 首次打开被拦

ad-hoc 签名（`-s -`）没有经过 Apple 公证，Gatekeeper 会拦：

- **右键 App →「打开」→ 再点「打开」**（只需一次）
- 或：系统设置 → 隐私与安全性 → 底部提示条 →「仍要打开」
- 或命令行：`xattr -cr /Applications/Txin.app`

想彻底免掉这一步，得 Apple Developer 账号（$99/年）做 Developer ID 签名 + 公证。workflow 末尾留了完整命令和环境变量清单。

---

## 6. 失败往哪看

| 报错 | 位置 | 处理 |
|---|---|---|
| `没找到 Package.swift` | 「定位工程根」 | 推的内容里得包含 `Package.swift` |
| `自检未通过` / `key 不一致` | 「协议金标自检」 | 真有问题，看日志里期望 vs 实际；对照 README 的协议速查 |
| `error: no such module 'CommonCrypto'` | 「编译」 | macOS SDK 的 modulemap 缺失，极少见；换 `macos-13` runner 试试 |
| `swift: command not found` | 「工具链信息」 | runner 选错了，必须是 `macos-*` |
| `签名失败` | 「打包 .app」 | 一般是 bundle 结构不全，看上面的 `find build/Txin.app` 输出 |
| Artifacts 是空的 | 最后一步 | `if-no-files-found: error` 会直接红，说明 `build/` 里没产物 |

任何一步都能单独重跑：Actions 页面右上「Re-run failed jobs」。

---

## 7. 本地能先验的，就别等 CI

CI 一次 3 分钟，本地跑这些是秒级：

```powershell
cd apple

# 结构自查：括号、跨 module 可见性、AppKit/AVKit import、List selection…
node scripts/lint_swift.mjs .

# 金标向量自洽：验证 gzip 剥头逻辑、AES 链路、cookie 向量
node scripts/verify_vectors.js

# 图标（已生成，改设计才需要）
python scripts/make_icon.py --out Resources
```

CI 上真正新增的检查只有一样：**Swift 编译器**。所以本地这三条绿了，CI 只剩编译期语法/类型问题。
