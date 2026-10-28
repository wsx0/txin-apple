#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_app_zip.py —— 在 Windows / Linux 上直接产出可用的 Txin.app.zip

为什么这么做：
    .app 本质就是一个目录（Info.plist + 一个可执行入口 + 资源）。
    Swift 版需要 macOS 编译，但 shell 运行时不需要 —— macOS 自带 bash/curl/openssl。
    所以这里直接组装一个「shell 壳 .app」，任何系统上都能生成，
    拷到 Mac 上解压即可运行。

    关键点：zip 里必须写入 Unix 权限位（0755），否则 macOS 上解压后
    可执行文件没有执行权限，双击必失败。zipfile 的 external_attr 能存这个。

用法:
    python scripts/make_app_zip.py                # 输出到 apple/dist/
    python scripts/make_app_zip.py --out /tmp/x
"""

from __future__ import annotations

import argparse
import os
import stat
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
APP_NAME = "Txin"
DISPLAY = "糖心"
VERSION = "1.0.0"
BUNDLE_ID = "com.txin.shell"

INFO_PLIST = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>CFBundleExecutable</key>\t\t<string>Txin</string>
\t<key>CFBundleIdentifier</key>\t\t<string>{BUNDLE_ID}</string>
\t<key>CFBundleName</key>\t\t<string>{DISPLAY}</string>
\t<key>CFBundleDisplayName</key>\t\t<string>{DISPLAY}</string>
\t<key>CFBundlePackageType</key>\t\t<string>APPL</string>
\t<key>CFBundleShortVersionString</key>\t<string>{VERSION}</string>
\t<key>CFBundleVersion</key>\t\t<string>1</string>
\t<key>CFBundleIconFile</key>\t\t<string>AppIcon</string>
\t<key>LSMinimumSystemVersion</key>\t<string>11.0</string>
\t<key>LSApplicationCategoryType</key>\t<string>public.app-category.video</string>
\t<key>NSHighResolutionCapable</key>\t<true/>
\t<key>NSHumanReadableCopyright</key>\t<string>Protocol research build · 2026-10</string>
</dict>
</plist>
"""

LAUNCHER = """#!/bin/bash
# Txin.app 入口：把交互界面交给 Terminal
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
chmod +x "$RES/txin.sh" 2>/dev/null
if [ -x /usr/bin/osascript ]; then
  /usr/bin/osascript <<'APPLESCRIPT'
tell application "Terminal"
    activate
    do script "'$RES/txin.sh' menu"
end tell
APPLESCRIPT
else
  exec "$RES/txin.sh" menu
fi
"""

INSTALLER = """#!/bin/bash
# 双击我：把 Txin.app 装进「应用程序」并放行
cd "$(dirname "$0")" || exit 1
printf '\\033]0;安装糖心\\007'
clear 2>/dev/null
echo "════════════════════════════════════════"
echo "  糖心 · 安装"
echo "════════════════════════════════════════"
echo

if [ ! -d "Txin.app" ]; then
  echo "✗ 当前目录里没有 Txin.app"
  read -r _; exit 1
fi

echo "▸ 修复权限位…"
chmod +x Txin.app/Contents/MacOS/Txin
chmod +x Txin.app/Contents/Resources/txin.sh 2>/dev/null

echo "▸ 清除隔离属性…"
xattr -cr Txin.app 2>/dev/null

echo "▸ ad-hoc 签名（Apple Silicon 必需）…"
codesign --force --deep --sign - Txin.app 2>&1 | sed 's/^/    /'
if codesign --verify --deep --strict Txin.app 2>/dev/null; then
  echo "    ✓ 签名校验通过"
else
  echo "    ! 签名校验未通过，仍可尝试打开"
fi

echo "▸ 复制到 /Applications…"
rm -rf "/Applications/Txin.app"
if cp -R Txin.app /Applications/ 2>/dev/null; then
  echo "    ✓ 已安装：/Applications/Txin.app"
  xattr -cr "/Applications/Txin.app" 2>/dev/null
  codesign --force --deep --sign - "/Applications/Txin.app" 2>/dev/null
  echo
  echo "▸ 启动一次试试…"
  open "/Applications/Txin.app"
else
  echo "    ✗ 复制失败（权限？）。手动把 Txin.app 拖进「应用程序」即可"
fi

echo
echo "完成。以后从启动台或「应用程序」里双击「糖心」即可。"
echo "命令行用法：  ./Txin.app/Contents/Resources/txin.sh --help"
echo
read -r _
"""


def write_file(path: Path, content: str, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(content)
    os.chmod(path, mode)


def build_tree(stage: Path) -> Path:
    app = stage / f"{APP_NAME}.app"
    if app.exists():
        import shutil
        shutil.rmtree(app)

    write_file(app / "Contents" / "Info.plist", INFO_PLIST, 0o644)
    write_file(app / "Contents" / "PkgInfo", "APPL????", 0o644)
    write_file(app / "Contents" / "MacOS" / "Txin", LAUNCHER, 0o755)

    # 运行时 = shell 实现（如果仓库里有 mac/txin.sh 就拷过来）
    runtime_src = ROOT / "Resources" / "txin.sh"
    if not runtime_src.exists():
        runtime_src = ROOT.parent / "mac" / "txin.sh"
    if not runtime_src.exists():
        print("✗ 找不到 txin.sh（Resources/ 或 ../mac/）", file=sys.stderr)
        sys.exit(2)
    dst = app / "Contents" / "Resources" / "txin.sh"
    write_file(dst, runtime_src.read_text(encoding="utf-8"), 0o755)

    # 向量
    for cand in (ROOT / "test-vectors.json", ROOT.parent / "mac" / "test-vectors.json"):
        if cand.exists():
            (app / "Contents" / "Resources").mkdir(parents=True, exist_ok=True)
            (app / "Contents" / "Resources" / "test-vectors.json").write_bytes(cand.read_bytes())
            break

    # 图标
    icon = ROOT / "Resources" / "AppIcon.icns"
    if icon.exists():
        import shutil
        shutil.copy2(icon, app / "Contents" / "Resources" / "AppIcon.icns")

    # 安装器（放在 app 外面，和 app 同级）
    write_file(stage / "安装.command", INSTALLER, 0o755)
    write_file(stage / "使用说明.txt", USAGE, 0o644)
    return app


USAGE = f"""糖心 · macOS 客户端（{VERSION}）
════════════════════════════════════════

不用编译，不用装任何东西。macOS 自带的 bash/curl/openssl 就够。

安装（两步）
────────────
1. 双击「安装.command」
2. 如果提示"来自身份不明的开发者"：
   右键点「安装.command」→ 打开 → 再点打开

装完从「应用程序」或启动台双击「糖心」。

命令行用法
────────────
  X="Txin.app/Contents/Resources/txin.sh"
  "$X" selftest          # 协议自检，9 项
  "$X" info              # 会话 / VIP / 镜像
  "$X" list 1 1          # 视频列表
  "$X" detail 309770     # 详情 + m3u8
  "$X" dl 309770         # 下载解密
  "$X" menu              # 交互菜单

下载的文件默认在  ~/Movies/txin/<作品ID>/
转 mp4 需要 ffmpeg：  brew install ffmpeg
  ffmpeg -i xxx.ts -c copy xxx.mp4

常见问题
────────────
· 双击没反应 / 提示已损坏
    打开「终端」，cd 到这个目录，运行：
      chmod +x 安装.command && xattr -cr Txin.app && ./安装.command

· 图片和视频下不下来
    国内 CDN 域名 whk.srslpoh.cn 被 DNS 劫持了。
    程序会自动切 CloudFront 镜像，用命令确认：
      "Txin.app/Contents/Resources/txin.sh" cdn
"""


def build_zip(stage: Path, out_zip: Path) -> None:
    """打包并把 Unix 权限位写进 zip（macOS 解压才不会丢执行位）

    注意：Windows 的 os.chmod 设不了执行位（NTFS 没这个概念），
    所以按文件名判定，不能靠 stat().st_mode。
    """
    out_zip.parent.mkdir(parents=True, exist_ok=True)
    if out_zip.exists():
        out_zip.unlink()

    entries: list[tuple[Path, str]] = []
    for p in sorted(stage.rglob("*")):
        rel = p.relative_to(stage).as_posix()
        if p.is_dir():
            entries.append((p, rel + "/"))
        else:
            entries.append((p, rel))

    with zipfile.ZipFile(out_zip, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p, arc in entries:
            if p.is_dir():
                zi = zipfile.ZipInfo(arc)
                zi.external_attr = (0o40755 << 16) | 0x10   # 目录 0755 + MS-DOS dir bit
                zi.create_system = 3                        # 3 = Unix
                z.writestr(zi, b"")
            else:
                name = arc.rsplit("/", 1)[-1]
                executable = arc.endswith(".command") or name in ("Txin", "txin.sh")
                mode = 0o755 if executable else 0o644
                zi = zipfile.ZipInfo(arc)
                zi.external_attr = mode << 16
                zi.create_system = 3
                zi.date_time = (2026, 10, 28, 0, 0, 0)
                zi.compress_type = zipfile.ZIP_DEFLATED
                z.writestr(zi, p.read_bytes())


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "dist"))
    ap.add_argument("--keep-stage", action="store_true")
    args = ap.parse_args()

    out_dir = Path(args.out)
    stage = out_dir / "stage"
    if stage.exists():
        import shutil
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    app = build_tree(stage)
    print(f"app     : {app}")

    out_zip = out_dir / f"{APP_NAME}-{VERSION}-mac.zip"
    build_zip(stage, out_zip)
    print(f"zip     : {out_zip}  ({out_zip.stat().st_size / 1024:.0f} KB)")

    # 自检：把 zip 里的权限位读回来确认
    with zipfile.ZipFile(out_zip) as z:
        bad = []
        for info in z.infolist():
            mode = (info.external_attr >> 16) & 0o777
            if info.filename.endswith((".command",)) or info.filename.endswith("/Txin") \
               or info.filename.endswith("txin.sh"):
                if mode & 0o111 == 0:
                    bad.append((info.filename, oct(mode)))
        if bad:
            print("✗ 以下条目缺执行位：")
            for f, m in bad:
                print(f"    {f}  {m}")
            return 3
        print("权限位 : 全部正确（可执行条目含 0755）")

    if not args.keep_stage:
        import shutil
        shutil.rmtree(stage)

    print()
    print("下一步：把 zip 拷到 Mac，双击解压 → 双击「安装.command」")
    return 0


if __name__ == "__main__":
    sys.exit(main())
