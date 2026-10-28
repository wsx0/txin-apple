#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_icon.py —— 生成 macOS 应用图标（.icns + .png）

Windows / macOS / Linux 都能跑（只要装了 Pillow）。
macOS 上 build-app.sh 会自动调用；也可以在 Windows 上先跑好，把 AppIcon.icns 一起提交。

用法:
    python scripts/make_icon.py --out Resources
"""

from __future__ import annotations

import argparse
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:
    print("需要 Pillow：pip install pillow", file=sys.stderr)
    sys.exit(2)

SIZES = [16, 32, 64, 128, 256, 512, 1024]


def rounded_mask(size: int, radius_ratio: float = 0.225) -> Image.Image:
    m = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(m)
    r = int(size * radius_ratio)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=r, fill=255)
    return m


def build(size: int = 1024) -> Image.Image:
    """深色底 + 暖色渐变 + 播放三角 + 胶片齿孔"""
    S = size
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 背景渐变（品红 → 橙）
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    top = (232, 62, 140)
    bottom = (255, 138, 51)
    for y in range(S):
        t = y / max(1, S - 1)
        # 加一点 S 曲线，避免线性发灰
        t = t * t * (3 - 2 * t)
        c = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
        gd.line([(0, y), (S, y)], fill=c + (255,))

    # 内层深色卡片
    card = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    cd = ImageDraw.Draw(card)
    pad = int(S * 0.115)
    cd.rounded_rectangle([pad, pad, S - pad, S - pad],
                         radius=int(S * 0.18), fill=(18, 16, 22, 232))

    # 胶片齿孔（上下两条）
    hole_w, hole_h = int(S * 0.052), int(S * 0.038)
    gap = int(hole_w * 1.85)
    y_top = int(S * 0.175)
    y_bot = int(S * 0.785)
    x = int(S * 0.19)
    while x + hole_w < S - int(S * 0.19):
        for yy in (y_top, y_bot):
            cd.rounded_rectangle([x, yy, x + hole_w, yy + hole_h],
                                 radius=int(hole_h * 0.35), fill=(255, 255, 255, 46))
        x += gap

    img = Image.alpha_composite(img, grad)
    img = Image.alpha_composite(img, card)

    # 播放三角
    tri = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(tri)
    cx, cy = S * 0.5, S * 0.5
    w = S * 0.20
    h = S * 0.26
    td.polygon([(cx - w * 0.55, cy - h),
                (cx - w * 0.55, cy + h),
                (cx + w * 0.95, cy)], fill=(255, 255, 255, 240))

    glow = tri.filter(ImageFilter.GaussianBlur(S * 0.035))
    img = Image.alpha_composite(img, glow)
    img = Image.alpha_composite(img, tri)

    # 圆角裁切
    mask = rounded_mask(S)
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="Resources", help="输出目录")
    ap.add_argument("--name", default="AppIcon", help="文件名（不含扩展名）")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    base = build(1024)

    png_path = os.path.join(args.out, f"{args.name}.png")
    base.save(png_path, "PNG")
    print(f"PNG  : {png_path}")

    # 各尺寸 PNG
    iconset = os.path.join(args.out, f"{args.name}.iconset")
    os.makedirs(iconset, exist_ok=True)
    pairs = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for px, fn in pairs:
        base.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, fn), "PNG")
    print(f"iconset: {iconset}")

    # macOS 上有 iconutil 就用它（最标准），否则 Pillow 直接写 icns
    icns_path = os.path.join(args.out, f"{args.name}.icns")
    made = False
    if sys.platform == "darwin":
        import subprocess
        try:
            subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns_path],
                           check=True, capture_output=True)
            made = True
        except Exception as e:
            print(f"iconutil 失败，回退 Pillow：{e}", file=sys.stderr)

    if not made:
        try:
            base.save(icns_path, format="ICNS", sizes=[(s, s) for s in SIZES])
            made = True
        except Exception as e:
            print(f"Pillow 写 icns 失败：{e}", file=sys.stderr)

    if made:
        print(f"ICNS : {icns_path} ({os.path.getsize(icns_path)} B)")
    else:
        print("没有生成 icns，App 会使用系统默认图标", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
