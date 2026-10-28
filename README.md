# 糖心 macOS 客户端（Txin.app）

把 `txinweb1.com` / `tangxgw.com` 的逆向成果做成苹果软件。
**两条产出路径，都能出 `Txin.app`：**

| 模式 | 需要什么 | 说明 |
|---|---|---|
| **零编译** | 一台 Mac，别的不要 | `.app` 的运行时是 shell（`Resources/txin.sh`），macOS 自带 `bash/curl/openssl` 就够 |
| **原生** | Mac + Command Line Tools | Swift 编译成原生二进制，体积更小、启动更快 |

`.app` 本质是个目录：`Info.plist` + 一个可执行入口 + 资源。**不需要 Xcode 工程、不需要签名证书。**

---

## 一、直接拿现成的（推荐先试这个）

仓库里已经有一个**在 Windows 上组装好的** zip：

```
apple/dist/Txin-1.0.0-mac.zip      184 KB
```

里面：

```
Txin.app/                          双击运行（shell 运行时）
  Contents/Info.plist
  Contents/MacOS/Txin              ← 入口，osascript 拉起 Terminal
  Contents/Resources/txin.sh       ← 运行时，646 行 bash
  Contents/Resources/test-vectors.json
  Contents/Resources/AppIcon.icns
安装.command                        双击自动：修权限 / 清隔离 / 签名 / 装进 /Applications
使用说明.txt
```

**macOS 上的用法（两步）：**

1. 拷到 Mac，双击解压
2. 右键 `安装.command` →「打开」（首次会被 Gatekeeper 拦一次）

装完从启动台或「应用程序」里双击「糖心」。

命令行也一样能用：

```bash
X="Txin.app/Contents/Resources/txin.sh"
"$X" selftest      # 协议自检 9 项
"$X" info          # 会话 / VIP / 镜像
"$X" detail 309770 # 详情 + m3u8
"$X" dl 309770     # 下载解密
```

> zip 里的 Unix 权限位是直接在 ZIP 头里写死的（`0755`）。这一点很关键——
> 如果在 Windows 上解压再拷到 Mac，执行位会丢，App 打不开。
> **必须整包拷过去，在 Mac 上解压。**

---

## 二、在 Mac 上自己构建

```bash
cd apple
chmod +x scripts/build-app.sh
./scripts/build-app.sh --dmg --run
```

脚本第一步永远是**协议金标自检**，不过就中止，不会给你一个跑起来才发现的坏 App。

然后自动选模式：

```
有 swift  →  swift build -c release --product TxinApp  → 原生二进制
没 swift  →  复制 Resources/txin.sh 作运行时            → shell 壳
```

强制指定：`--native` / `--shell`

产物：

```
build/Txin.app          双击即用
build/Txin-1.0.0.dmg    加 --dmg 才有
```

### 在非 Mac 上组装 zip

```bash
python scripts/make_app_zip.py --out dist
```

Windows / Linux 都能跑，产出的 zip 权限位正确，拷到 Mac 解压即用。
`scripts/make_app_zip.py` 就是生成上面那个 184 KB 包的东西。

---

## 三、GitHub Actions（可选）

`.github/workflows/macos-app.yml` 是完整流水线：`macos-14` runner，先跑金标自检再打包，产物上传 Artifacts。

需要把仓库推到 GitHub（**必须自己的账号，CI 没法匿名跑**）。推上去后 Actions 自动触发，3~6 分钟出 `Txin-macos-<N>.zip`。

没有 GitHub 账号也不影响——模式①②不需要它。

---

## 四、协议速查

**会话 cookie**：AES-128-ECB / PKCS7，key = `4ntmubrorxzqalmq`

| cookie | 内容 |
|---|---|
| `c_tt` | `{"user_id","token","is_vip","has_login",…}` |
| `c_dd` | deviceId（JSON 字符串，要剥引号） |

**API 请求**：

```
requestId = uuid v4（每次新生成）
key       = HMAC-SHA256( message = hex(requestId 去横线), HMAC-key = "x3t8rvtaescfe38s" )  // 32B
body      = base64( IV(16) || AES-256-CBC( gzip(JSON({data,token,deviceId})), key, IV ) )
headers   = Content-Type: text/plain, time(11位), version, deviceType: web, requestId, language
```

**API 响应**：同一把 key，`IV = resp[0:16]`、`ct = resp[16:]`，解密后 gunzip 再 JSON。

**播放**：`/movie/detail` → `play_links[].m3u8_url`（游客可取，后端不鉴权）→
`/api/m3u8/p/<hash>.m3u8`（明文）→ `#EXT-X-KEY:METHOD=AES-128` → 分片。

**三套密钥体系，别搞混：**

| 层 | 算法 | 密钥 |
|---|---|---|
| API 请求/响应 | AES-256-CBC + PKCS7 | `HMAC-SHA256(uuid_hex, secret)` |
| 会话 cookie | AES-128-ECB | 固定字符串 |
| HLS 分片 | **AES-128**-CBC 无 padding | 播放列表里的 `URI=` + `IV=` |

---

## 五、已知坑

| 现象 | 原因 | 处理 |
|---|---|---|
| 双击提示"无法验证开发者" | ad-hoc 签名未公证 | 右键 App →「打开」；或跑一次 `安装.command` |
| App 闪退 / "已损坏" | 执行位丢了（Windows 解压导致） | `chmod +x Txin.app/Contents/MacOS/Txin` + `xattr -cr` + `codesign -s -` |
| 图片全灰、下载失败 | `whk.srslpoh.cn` 被 DNS 劫持 | 程序自动切 CloudFront；用 `txin.sh cdn` 确认 |
| 下载完 `.ts` 放不出来 | AES 模式用错 | 必须是 `-aes-128-cbc -nopad`，写成 256 不报错但解出乱码 |
| 自检 `key 不一致` | requestId 处理错 | HMAC 的 message 是**十六进制字节**，不是字符串 |
| `swift: command not found` | 没装工具链 | `xcode-select --install`，或用 `--shell` 模式 |

---

## 六、目录

```
apple/
├── Package.swift                       Swift 工程（TxinKit / txin / TxinApp）
├── test-vectors.json                   协议金标（Node 生成，与真实站点对齐）
├── Sources/
│   ├── TxinKit/                        Crypto / Gzip / CDN / Models / TxinAPI / HLS / SelfTest
│   ├── txin/CLI.swift
│   └── TxinApp/                        TxinApp / AppStore / ContentView / DetailPane / SettingsView
├── Resources/
│   ├── Info.plist                      原生模式用
│   ├── AppIcon.icns                    已生成
│   └── txin.sh                         零编译模式的运行时（从 mac/txin.sh 同步）
├── scripts/
│   ├── build-app.sh                    双模式：native / shell
│   ├── make_app_zip.py                 跨平台组装 .app.zip（写死 Unix 权限位）
│   ├── make_icon.py                    生成 icns
│   ├── lint_swift.mjs                  Swift 静态结构检查
│   └── verify_vectors.js               金标向量自洽校验
├── dist/
│   └── Txin-1.0.0-mac.zip              ★ 现成产物，拷到 Mac 就能用
└── .github/workflows/macos-app.yml     CI 流水线（可选）
```

---

## 七、Windows 上能验什么

这台机器没有 Swift，但下面这些已经在跑：

```powershell
node scripts/lint_swift.mjs .        # 14 文件 2498 行，无结构性问题
node scripts/verify_vectors.js       # 通过 7 项
python scripts/make_app_zip.py       # 组装 + 校验权限位
python scripts/make_icon.py          # 生成 icns
```

还有一条更硬的：`mac/txin.sh` 已在 Git Bash 上**完整跑通真实站点**——
`selftest` 9 项全绿，`dl 309770` 产出的 `.ts` 与 Node 参考实现 **MD5 逐字节相同**。
`apple/Resources/txin.sh` 就是同一个文件。
