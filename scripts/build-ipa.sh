#!/bin/bash
# ============================================================
#  build-ipa.sh —— 在 macOS 上把 ios/ 工程打成 .ipa
#
#  ipa = Payload/Txin.app + zip。iOS 必须有编译好的 ARM64 Mach-O
#  和有效签名，不像 macOS 那样能拿 shell 当入口 —— 这一步只能在 Mac 上做。
#
#  三种模式：
#    --unsigned            未签名 ipa（给 TrollStore / Sideloadly / AltStore 自签）
#    --signed --team TID   用开发者账号签名导出（需 Xcode 登录过该团队）
#    --device              直接装到已连接的 iPhone（需签名）
#
#  依赖：macOS + Xcode（不是只有 Command Line Tools）
# ============================================================
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PROJ="$ROOT/ios/TxinApp.xcodeproj"
PODFILE="$ROOT/ios/Podfile"
WS="$ROOT/ios/TxinApp.xcworkspace"
SCHEME="Txin"
CONFIG="Release"
VERSION="1.0.0"
OUT="$ROOT/build"

MODE="unsigned"
TEAM=""
BUNDLE_ID=""

for a in "$@"; do
  case "$a" in
    --unsigned) MODE="unsigned" ;;
    --signed)   MODE="signed" ;;
    --device)   MODE="device" ;;
    --team)     shift; TEAM="${1:-}" ;;
    --bundle)   shift; BUNDLE_ID="${1:-}" ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
  esac
done

say() { printf "\033[1;36m▸\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# ---------- 0. 环境 ----------
[ "$(uname -s)" = "Darwin" ] || die "只能在 macOS 上跑（ipa 必须由 Xcode 编译）"
command -v xcodebuild >/dev/null 2>&1 || die "找不到 xcodebuild。装 Xcode（不是 CLT）"
xcodebuild -version 2>/dev/null | head -2 | sed 's/^/    /'
[ -d "$PROJ" ] || die "工程不存在：$PROJ（先跑 python3 tools/gen_ios_xcodeproj.py）"

# 工程重新生成一次，保证新加的源文件都进 Sources
if command -v python3 >/dev/null 2>&1 && [ -f "$ROOT/tools/gen_ios_xcodeproj.py" ]; then
  say "刷新工程文件…"
  python3 "$ROOT/tools/gen_ios_xcodeproj.py" --quiet || die "生成工程失败"
fi

mkdir -p "$OUT"

# ---------- 0.5 CocoaPods ----------
# 顺序很重要：先由生成器产出 project.pbxproj，再 pod install 往里面注入 Pods 引用。
# 反过来做的话，生成器会把 pod 的改动覆盖掉。
BUILD_REF=(-project "$PROJ")
if [ -f "$PODFILE" ]; then
  command -v pod >/dev/null 2>&1 || die "找不到 pod。先装 CocoaPods：sudo gem install cocoapods"
  say "pod install（会下载 VLCKit，首次约 200MB）…"
  ( cd "$ROOT/ios" && pod install --repo-update 2>&1 | tail -25 ) || die "pod install 失败"
  [ -d "$WS" ] || die "pod install 没生成 workspace：$WS"
  BUILD_REF=(-workspace "$WS")
  say "改用 workspace 构建：$(basename "$WS")"
fi

# ---------- 1. 未签名 ----------
if [ "$MODE" = "unsigned" ]; then
  say "编译（不签名）…"
  xcodebuild \
    "${BUILD_REF[@]}" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -sdk iphoneos \
    -derivedDataPath "$OUT/dd" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    clean build 2>&1 | grep -E "error:|warning: .*(deprecated|unused)|BUILD (SUCCEEDED|FAILED)|\*\* " | head -80 || true

  APP="$OUT/dd/Build/Products/$CONFIG-iphoneos/Txin.app"
  [ -d "$APP" ] || die "没找到产物：$APP"

  say "校验 Mach-O…"
  BIN="$APP/Txin"
  file "$BIN" | sed 's/^/    /'
  lipo -info "$BIN" | sed 's/^/    /'
  # 必须是 ARM64 的 Mach-O，且带 iOS 平台标记
  file "$BIN" | grep -q "Mach-O" || die "不是 Mach-O，编译没成功"
  file "$BIN" | grep -qi "arm64" || die "不是 arm64，检查 ARCHS 设置"

  say "打包 ipa…"
  IPA_DIR="$OUT/ipa-unsigned"
  rm -rf "$IPA_DIR"
  mkdir -p "$IPA_DIR/Payload"
  cp -R "$APP" "$IPA_DIR/Payload/"
  IPA="$OUT/Txin-$VERSION-unsigned.ipa"
  rm -f "$IPA"
  ( cd "$IPA_DIR" && zip -qry "$IPA" Payload )
  rm -rf "$IPA_DIR"

  say "完成：$IPA  ($(du -sh "$IPA" | cut -f1))"
  cat <<EOF

  这个 ipa **没有签名**，不能直接双击装到普通 iPhone。三条路：

  1) TrollStore（iOS 14.0–16.6.1 部分版本）
     拷进设备，用 TrollStore 打开 → 永久签名，无需电脑

  2) Sideloadly / AltStore（任意 iOS，需电脑）
     用免费 Apple ID 自签，7 天有效，到期重签

  3) Xcode 手动装
     open ios/TxinApp.xcodeproj → 选你的设备 → Run（需登录 Apple ID）

  想出一份能直接装的签名包，用：
     ./scripts/build-ipa.sh --signed --team <你的TeamID>
EOF
  exit 0
fi

# ---------- 2. 已签名 / 直装 ----------
TEAM="${TEAM:-${DEVELOPMENT_TEAM:-}}"
if [ -z "$TEAM" ]; then
  say "可用团队："
  security find-identity -v -p codesigning 2>/dev/null | sed 's/^/    /' || true
  die "需要 --team <TeamID>（Xcode → Settings → Accounts 里能看到）"
fi

if [ "$MODE" = "device" ]; then
  say "直接装到连接的设备…"
  DEV=$(xcrun devicectl list devices 2>/dev/null | grep -i "connected" | head -1 | awk '{print $1}')
  [ -n "$DEV" ] || die "没找到已连接的设备（解锁手机、信任此电脑）"
  xcodebuild "${BUILD_REF[@]}" -scheme "$SCHEME" -configuration "$CONFIG" \
    -destination "id=$DEV" \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Automatic \
    build 2>&1 | tail -20
  say "完成"
  exit 0
fi

say "归档（archive）…"
ARCH="$OUT/Txin.xcarchive"
rm -rf "$ARCH"
xcodebuild \
  "${BUILD_REF[@]}" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -archivePath "$ARCH" \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  archive 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)|\*\* " | head -40 || true
[ -d "$ARCH" ] || die "archive 失败"

say "导出 ipa…"
EXPORT_PLIST="$ROOT/ios/ExportOptions.plist"
if [ -n "$BUNDLE_ID" ]; then
  sed "s|<string>com.txin.ios</string>|<string>$BUNDLE_ID</string>|g" \
      "$EXPORT_PLIST" > "$OUT/ExportOptions.plist"
  EXPORT_PLIST="$OUT/ExportOptions.plist"
fi

rm -rf "$OUT/ipa-signed"
xcodebuild -exportArchive \
  -archivePath "$ARCH" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -exportPath "$OUT/ipa-signed" 2>&1 | tail -20

IPA=$(find "$OUT/ipa-signed" -name "*.ipa" -maxdepth 2 | head -1)
if [ -n "$IPA" ]; then
  FINAL="$OUT/Txin-$VERSION.ipa"
  mv "$IPA" "$FINAL"
  say "完成：$FINAL  ($(du -sh "$FINAL" | cut -f1))"
  codesign -dv --verbose=2 "$OUT/Txin.xcarchive/Products/Applications/Txin.app" 2>&1 | head -6 | sed 's/^/    /' || true
  echo
  echo "  装到手机：  xcrun devicectl device install app --device <UDID> \"$OUT/Txin.xcarchive/Products/Applications/Txin.app\""
  echo "  或用 Apple Configurator / Sideloadly 装 $FINAL"
else
  die "导出没产出 ipa，看上面的 xcodebuild 输出"
fi
