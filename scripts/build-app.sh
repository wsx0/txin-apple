#!/bin/bash
# ============================================================
#  build-app.sh —— 在 macOS 上产出 Txin.app
#
#  两条路自动选，都出 .app：
#    ① 有 swift（装了 Command Line Tools）  → 编译原生 Swift 二进制
#    ② 没有 swift                          → 用 Resources/txin.sh 作运行时（零编译）
#
#  用法:
#    ./scripts/build-app.sh              # 出 .app
#    ./scripts/build-app.sh --dmg        # 顺带出 dmg
#    ./scripts/build-app.sh --shell      # 强制走零编译模式
#    ./scripts/build-app.sh --native     # 强制走 Swift 编译
#    ./scripts/build-app.sh --run        # 打完直接打开
# ============================================================
set -eu

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_NAME="Txin"
BUNDLE="$ROOT/build/$APP_NAME.app"
DISPLAY_NAME="糖心"
VERSION="1.0.0"

MAKE_DMG=0
RUN_AFTER=0
FORCE=""

for a in "$@"; do
  case "$a" in
    --dmg)    MAKE_DMG=1 ;;
    --run)    RUN_AFTER=1 ;;
    --shell)  FORCE="shell" ;;
    --native) FORCE="native" ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
  esac
done

say() { printf "\033[1;36m▸\033[0m %s\n" "$*"; }
die() { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# ---------- 0. 选模式 ----------
HAVE_SWIFT=0
command -v swift >/dev/null 2>&1 && HAVE_SWIFT=1

MODE="$FORCE"
if [ -z "$MODE" ]; then
  if [ "$HAVE_SWIFT" = "1" ]; then MODE="native"; else MODE="shell"; fi
fi

if [ "$MODE" = "native" ] && [ "$HAVE_SWIFT" = "0" ]; then
  die "要求 native 模式但找不到 swift。装：xcode-select --install，或改用 --shell"
fi
if [ "$MODE" = "shell" ] && [ ! -f "$ROOT/Resources/txin.sh" ]; then
  die "shell 模式需要 Resources/txin.sh（从 mac/txin.sh 复制一份过来）"
fi

if [ "$MODE" = "native" ]; then
  say "模式：Swift 原生编译"
  say "工具链：$(swift --version 2>&1 | head -1)"
else
  say "模式：零编译（shell 运行时，macOS 自带工具即可）"
fi

OS_MAJOR="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1 || echo 0)"
[ "${OS_MAJOR:-0}" -ge 11 ] 2>/dev/null || say "提示：当前 macOS $(sw_vers -productVersion 2>/dev/null || echo '?')，产物要求 11.0+"

# ---------- 1. 协议自检（两种模式都要过） ----------
say "协议金标自检…"
if [ "$MODE" = "native" ]; then
  swift build -c release --product txin >/dev/null || die "编译 CLI 失败"
  "$ROOT/.build/release/txin" selftest --vectors "$ROOT/test-vectors.json" || die "自检未通过"
else
  chmod +x "$ROOT/Resources/txin.sh"
  "$ROOT/Resources/txin.sh" selftest "$ROOT/test-vectors.json" || die "自检未通过"
fi

# ---------- 2. 组装 bundle ----------
say "组装 bundle…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

if [ "$MODE" = "native" ]; then
  say "编译 App（release）…"
  swift build -c release --product TxinApp
  BIN="$ROOT/.build/release/TxinApp"
  [ -f "$BIN" ] || die "产物不存在：$BIN"
  cp "$BIN" "$BUNDLE/Contents/MacOS/Txin"
  chmod +x "$BUNDLE/Contents/MacOS/Txin"
  cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
else
  cp "$ROOT/Resources/txin.sh" "$BUNDLE/Contents/Resources/txin.sh"
  chmod +x "$BUNDLE/Contents/Resources/txin.sh"
  cat > "$BUNDLE/Contents/MacOS/Txin" <<'LAUNCH'
#!/bin/bash
# Txin.app 入口（shell 运行时）：把交互界面交给 Terminal
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
LAUNCH
  chmod +x "$BUNDLE/Contents/MacOS/Txin"

  cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>          <string>Txin</string>
	<key>CFBundleIdentifier</key>          <string>com.txin.shell</string>
	<key>CFBundleName</key>                <string>$DISPLAY_NAME</string>
	<key>CFBundleDisplayName</key>         <string>$DISPLAY_NAME</string>
	<key>CFBundlePackageType</key>         <string>APPL</string>
	<key>CFBundleShortVersionString</key>  <string>$VERSION</string>
	<key>CFBundleVersion</key>             <string>1</string>
	<key>CFBundleIconFile</key>            <string>AppIcon</string>
	<key>LSMinimumSystemVersion</key>      <string>11.0</string>
	<key>LSApplicationCategoryType</key>   <string>public.app-category.video</string>
	<key>NSHighResolutionCapable</key>     <true/>
	<key>NSHumanReadableCopyright</key>    <string>Protocol research build · 2026-10</string>
</dict>
</plist>
PLIST
  cp "$ROOT/test-vectors.json" "$BUNDLE/Contents/Resources/" 2>/dev/null || true
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true

# ---------- 3. 图标 ----------
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
  say "图标：Resources/AppIcon.icns"
elif command -v python3 >/dev/null 2>&1 && [ -f "$ROOT/scripts/make_icon.py" ]; then
  say "图标：现场生成…"
  python3 "$ROOT/scripts/make_icon.py" --out "$ROOT/Resources" >/dev/null 2>&1 || true
  [ -f "$ROOT/Resources/AppIcon.icns" ] && cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/"
else
  say "图标：跳过（无 icns）"
fi

printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

# ---------- 4. 签名 ----------
say "ad-hoc 签名…"
codesign --force --deep --sign - "$BUNDLE" 2>&1 | sed 's/^/    /' || die "签名失败"
codesign --verify --deep --strict "$BUNDLE" && say "签名校验通过"
xattr -cr "$BUNDLE" 2>/dev/null || true

say "完成：$BUNDLE  ($(du -sh "$BUNDLE" | cut -f1))"

# ---------- 5. 可选 ----------
if [ "$MAKE_DMG" = "1" ]; then
  DMG="$ROOT/build/$APP_NAME-$VERSION.dmg"
  say "打包 dmg…"
  STAGE="$ROOT/build/dmg-stage"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$BUNDLE" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "$DMG"
  hdiutil create -volname "$DISPLAY_NAME $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  say "完成：$DMG ($(du -sh "$DMG" | cut -f1))"
fi

[ "$RUN_AFTER" = "1" ] && open "$BUNDLE"

cat <<EOF

──────────────────────────────────────────
 模式     : $MODE
 双击打开 : $BUNDLE
 命令行   : $ROOT/Resources/txin.sh --help
 首次运行 : 右键 →「打开」放行一次
──────────────────────────────────────────
EOF
