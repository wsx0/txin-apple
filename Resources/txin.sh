#!/bin/bash
# ============================================================================
#  txin.sh —— 糖心 (tangxgw.com / txinweb1.com) 客户端 · 纯 shell 实现
#
#  设计目标：macOS 开箱即用，零编译、零第三方依赖、零 SDK。
#  只用系统自带：bash / curl / openssl / gzip / xxd / awk / sed / perl
#
#  兼容性：bash 3.2（macOS 默认）、LibreSSL（macOS /usr/bin/openssl）
#          同时能在 Linux(GNU) 与 Git Bash(OpenSSL 3) 上跑
#
#  协议（逆向自 /_nuxt/DeE7C1J3.js class wl）：
#    secret    = x3t8rvtaescfe38s
#    requestId = uuid v4
#    key       = HMAC-SHA256(msg = hex(requestId 去横线), key = secret)   → 32B
#    body      = base64( IV(16) || AES-256-CBC( gzip(JSON), key, IV ) )
#    headers   = Content-Type: text/plain, time, version, deviceType, requestId, language
#    响应       = 同一 key，IV = resp[0:16]，解完 gunzip
#    会话 cookie c_tt = AES-128-ECB(key = 4ntmubrorxzqalmq)
# ============================================================================

set -u

HOST="${TXIN_HOST:-https://tangxgw.com}"
SECRET='x3t8rvtaescfe38s'
COOKIE_KEY_HEX='346e746d7562726f72787a71616c6d71'   # "4ntmubrorxzqalmq"
UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15'
MIRROR_FROM='https://whk.srslpoh.cn/'
MIRROR_TO='https://d22i72z1otaemb.cloudfront.net/'

WORK=""
# 脚本自身所在目录（.app bundle 里也能正确定位 test-vectors.json）
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$SCRIPT_DIR" ] || SCRIPT_DIR="."
cleanup() { [ -n "$WORK" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- 基础工具

die()  { printf '\033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }
say()  { printf '\033[1;36m▸\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

require_tools() {
  need curl
  need openssl
  need gzip
  need awk
  need sed
  # xxd 可选（有 perl 兜底）
  if ! command -v xxd >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
    die "需要 xxd 或 perl 之一（用于 hex<->binary）"
  fi
}

hex2bin() {
  if command -v xxd >/dev/null 2>&1; then
    xxd -r -p
  else
    perl -e 'local $/; my $h=<STDIN>; $h=~s/\s//g; print pack("H*",$h)'
  fi
}

bin2hex() {
  if command -v xxd >/dev/null 2>&1; then
    xxd -p -c 1000000 | tr -d '\n'
  else
    perl -e 'local $/; my $b=<STDIN>; print unpack("H*",$b)'
  fi
}

rand_hex() {  # $1 = 字节数
  if [ -r /dev/urandom ]; then
    dd if=/dev/urandom bs=1 count="$1" 2>/dev/null | bin2hex
  else
    perl -e "print unpack('H*', join('', map { chr(int(rand 256)) } 1..$1))"
  fi
}

uuid4() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr 'A-Z' 'a-z'
  else
    perl -e 'my @b=map { int(rand 256) } 1..16;
             $b[6]=($b[6]&0x0f)|0x40; $b[8]=($b[8]&0x3f)|0x80;
             printf "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x", @b'
  fi
}

b64enc() { openssl enc -base64 -A; }
b64dec() { openssl enc -base64 -d -A 2>/dev/null; }

url_decode() {
  perl -pe 's/%([0-9A-Fa-f]{2})/chr(hex($1))/ge'
}

# ---------------------------------------------------------------- 密码学

hmac_sha256_hex() {  # $1 = hex message, $2 = 字符串 key
  printf '%s' "$1" | hex2bin | openssl dgst -sha256 -hmac "$2" -binary | bin2hex
}

aes_cbc_enc() {  # $1=hexkey $2=hexiv  stdin -> stdout（PKCS7）
  openssl enc -aes-256-cbc -K "$1" -iv "$2" -nosalt
}

aes_cbc_dec() {  # PKCS7
  openssl enc -d -aes-256-cbc -K "$1" -iv "$2" -nosalt
}

aes_cbc_dec_nopad() {  # HLS 分片：METHOD=AES-128 → 必须 -aes-128-cbc（16 字节 key），无 padding
  openssl enc -d -aes-128-cbc -K "$1" -iv "$2" -nosalt -nopad
}

aes_ecb_dec128() {  # $1 = hexkey
  openssl enc -d -aes-128-ecb -K "$1" -nosalt
}

# ---------------------------------------------------------------- 会话

SESSION_JAR=""

bootstrap() {
  [ -n "$SESSION_JAR" ] && return 0
  # 复用调用方已建好的 WORK，别覆盖（否则 cmd_* 里的路径全错位）
  [ -n "$WORK" ] && [ -d "$WORK" ] || WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX") || die "无法创建临时目录"
  SESSION_JAR="$WORK/cookies.txt"

  say "建立会话…"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' -c "$SESSION_JAR" \
              -H "User-Agent: $UA" "$HOST/" 2>/dev/null) || die "连不上 $HOST"
  [ "$code" = "200" ] || die "首页返回 $code"

  local ctt cdd
  ctt=$(awk '$6=="c_tt"{print $7}' "$SESSION_JAR" 2>/dev/null | tail -1)
  cdd=$(awk '$6=="c_dd"{print $7}' "$SESSION_JAR" 2>/dev/null | tail -1)
  [ -n "$ctt" ] || die "没拿到 c_tt，站点可能改协议了"

  PROFILE_JSON=$(printf '%s' "$ctt" | url_decode | b64dec | aes_ecb_dec128 "$COOKIE_KEY_HEX" 2>/dev/null)
  [ -n "$PROFILE_JSON" ] || die "c_tt 解密失败"

  P_TOKEN=$(printf '%s' "$PROFILE_JSON" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  P_UID=$(printf '%s'   "$PROFILE_JSON" | sed -n 's/.*"user_id":"\([^"]*\)".*/\1/p')
  P_NAME=$(printf '%s'  "$PROFILE_JSON" | sed -n 's/.*"nickname":"\([^"]*\)".*/\1/p')
  P_VIP=$(printf '%s'   "$PROFILE_JSON" | sed -n 's/.*"is_vip":"\([^"]*\)".*/\1/p')
  P_LOGIN=$(printf '%s' "$PROFILE_JSON" | sed -n 's/.*"has_login":"\([^"]*\)".*/\1/p')

  if [ -n "$cdd" ]; then
    P_DEVICE=$(printf '%s' "$cdd" | url_decode | b64dec | aes_ecb_dec128 "$COOKIE_KEY_HEX" 2>/dev/null | tr -d '"')
  fi
  [ -n "${P_DEVICE:-}" ] || P_DEVICE=$(uuid4)
  return 0
}

# ---------------------------------------------------------------- API

# 调接口，结果（JSON 明文）写到 $1
api_call() {  # $1 = out file, $2 = path, $3 = data JSON (默认 {})
  local out="$1" path="$2" data="${3:-{\}}"
  bootstrap

  local rid key iv ivbin env body ct resp code
  rid=$(uuid4)
  key=$(hmac_sha256_hex "$(printf '%s' "$rid" | tr -d '-')" "$SECRET")
  iv=$(rand_hex 16)

  local tok=""
  if [ -n "${P_TOKEN:-}" ] && [ -n "${P_UID:-}" ]; then
    tok="${P_TOKEN}_${P_UID}"
  fi

  env="{\"data\":${data},\"token\":\"${tok}\",\"deviceId\":\"${P_DEVICE}\"}"

  # gzip -> AES-256-CBC -> base64(IV||CT)
  printf '%s' "$env" | gzip -n -c > "$WORK/gz.bin"
  openssl enc -aes-256-cbc -K "$key" -iv "$iv" -nosalt \
          -in "$WORK/gz.bin" -out "$WORK/ct.bin" || die "AES 加密失败"
  hex2bin > "$WORK/body.bin" <<EOF
$iv
EOF
  cat "$WORK/ct.bin" >> "$WORK/body.bin"
  b64enc < "$WORK/body.bin" > "$WORK/body.b64"

  local ts
  ts=$(perl -e 'my $t=int(time()*1000); print substr("$t",0,11)')

  code=$(curl -sS -o "$WORK/resp.bin" -w '%{http_code}' -b "$SESSION_JAR" -c "$SESSION_JAR" \
    -X POST \
    -H 'Content-Type: text/plain' \
    -H "time: $ts" \
    -H 'version: 1.0.0' \
    -H 'deviceType: web' \
    -H "requestId: $rid" \
    -H 'language: zh-cn' \
    -H "User-Agent: $UA" \
    -H "Referer: $HOST/" \
    --data-binary "@$WORK/body.b64" \
    "$HOST/api$path" 2>/dev/null) || die "请求 $path 失败"

  [ "$code" = "200" ] || die "HTTP $code @ $path"

  local size
  size=$(wc -c < "$WORK/resp.bin" | tr -d ' ')
  [ "$size" -gt 32 ] || die "响应过短（${size}B），可能是协议变更"

  # 响应可能是裸二进制，也可能是 base64 文本
  local isb64=0
  if LC_ALL=C grep -qE '^[A-Za-z0-9+/=[:space:]]+$' "$WORK/resp.bin" 2>/dev/null; then
    isb64=1
  fi
  if [ "$isb64" = "1" ]; then
    b64dec < "$WORK/resp.bin" > "$WORK/raw.bin"
  else
    cp "$WORK/resp.bin" "$WORK/raw.bin"
  fi

  dd if="$WORK/raw.bin" of="$WORK/iv.bin" bs=16 count=1 2>/dev/null
  dd if="$WORK/raw.bin" of="$WORK/c.bin"  bs=16 skip=1 2>/dev/null

  local riv rhex
  riv=$(bin2hex < "$WORK/iv.bin")
  if ! aes_cbc_dec "$key" "$riv" < "$WORK/c.bin" > "$WORK/plain.bin" 2>/dev/null; then
    die "响应解密失败（requestId 没对齐？）"
  fi

  if gzip -dc < "$WORK/plain.bin" > "$out" 2>/dev/null && [ -s "$out" ]; then
    return 0
  fi
  cp "$WORK/plain.bin" "$out"
}

pretty() {  # 粗略美化 JSON
  sed -e 's/},{/},\
{/g' -e 's/,"/,\
"/g' "$1" 2>/dev/null || cat "$1"
}

json_str() {  # $1=json file, $2=key —— 取第一个匹配的字符串值（perl：非贪婪、可处理 \" 转义）
  perl -e 'local $/; my $j = <STDIN>; my $k = shift;
           if ($j =~ /"\Q$k\E"\s*:\s*"((?:[^"\\]|\\.)*)"/s) { print $1 }' "$2" < "$1"
}

# JSON 里的 \uXXXX 转成真字符（接口大量中文都是转义形式）
unescape_unicode() {
  perl -CS -pe 's/\\u([0-9a-fA-F]{4})/chr(hex($1))/ge' 2>/dev/null || cat
}

# ---------------------------------------------------------------- CDN

cdn_rewrite() {
  sed "s|$MIRROR_FROM|$MIRROR_TO|g"
}

cdn_probe() {
  local code ctype sz=0
  [ -d "$WORK" ] || WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  code=$(curl -sS -o "$WORK/probe.bin" -w '%{http_code}' -D "$WORK/probe.hdr" \
              -H "User-Agent: $UA" \
              "$MIRROR_FROM""hc237/common_file/headico/common/122.bnc" 2>/dev/null || echo 000)
  [ -f "$WORK/probe.hdr" ] && ctype=$(tr -d '\r' < "$WORK/probe.hdr" \
      | awk -F': ' 'tolower($1)=="content-type"{print tolower($2); exit}')
  if [ -f "$WORK/probe.bin" ]; then
    sz=$(wc -c < "$WORK/probe.bin" | tr -d ' ')
  fi
  if [ "$code" = "200" ] && [ "${sz:-0}" != "11545" ] && [ "${ctype:-}" != "text/html" ]; then
    echo "ok"
  else
    echo "hijacked"
  fi
}

# ---------------------------------------------------------------- 命令

cmd_selftest() {
  local vectors="${1:-}"
  [ -n "$vectors" ] || { [ -f "$SCRIPT_DIR/test-vectors.json" ] && vectors="$SCRIPT_DIR/test-vectors.json"; }
  [ -n "$vectors" ] || { [ -f "./test-vectors.json" ] && vectors="./test-vectors.json"; }
  [ -n "$vectors" ] || { [ -f "../test-vectors.json" ] && vectors="../test-vectors.json"; }
  [ -n "$vectors" ] || die "找不到 test-vectors.json（用参数指定路径）"
  [ -f "$vectors" ] || die "向量文件不存在：$vectors"

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  local pass=0 fail=0
  local secret="" cookie_key="" cookie_plain="" cookie_cipher=""

  printf '向量文件: %s\n\n' "$vectors"

  # 用 perl 核心模块 JSON::PP 解析（macOS 自带 perl 5.30 与 Git Bash 的 perl 都有）
  perl -MJSON::PP -e '
    local $/; my $d = JSON::PP->new->decode(<STDIN>);
    print "SECRET|", ($d->{secret} // ""), "\n";
    print "COOKIEKEY|", ($d->{cookieKey} // ""), "\n";
    print "COOKIEPLAIN|", ($d->{cookieVector}{plaintext} // ""), "\n";
    print "COOKIECIPHER|", ($d->{cookieVector}{cipherBase64} // ""), "\n";
    for my $v (@{$d->{requestVectors}}) {
      print join("|",
        "VEC",
        ($v->{requestId} // ""),
        ($v->{keyHex} // ""),
        ($v->{ivHex} // ""),
        ($v->{bodyBase64} // ""),
        ($v->{gzipBase64} // ""),
        ($v->{payload}{deviceId} // ""),
        ($v->{payload}{token} // ""),
      ), "\n";
    }
  ' < "$vectors" > "$WORK/vec.txt" 2> "$WORK/vec.err" \
    || die "解析向量失败：$(cat "$WORK/vec.err" 2>/dev/null)"

  local n=0
  while IFS='|' read -r tag f1 f2 f3 f4 f5 f6 f7; do
    case "$tag" in
      SECRET)       secret="$f1";       continue ;;
      COOKIEKEY)    cookie_key="$f1";   continue ;;
      COOKIEPLAIN)  cookie_plain="$f1"; continue ;;
      COOKIECIPHER) cookie_cipher="$f1";continue ;;
      VEC) ;;
      *) continue ;;
    esac

    n=$((n + 1))
    local rid="$f1" kexp="$f2" bexp="$f4" xdev="$f6"

    # ---- 1. 密钥派生：HMAC-SHA256(hex(requestId 去横线), secret)
    local kgot
    kgot=$(hmac_sha256_hex "$(printf '%s' "$rid" | tr -d '-')" "$secret")
    if [ "$kgot" = "$kexp" ]; then
      pass=$((pass + 1)); printf '  ✓ 向量#%d key 派生一致\n' "$n"
    else
      fail=$((fail + 1))
      printf '  ✗ 向量#%d key 不一致\n    期望 %s\n    实际 %s\n' "$n" "$kexp" "$kgot"
    fi

    # ---- 2. 解金标密文：base64 -> IV(16) + AES-256-CBC -> gunzip
    if [ -n "$bexp" ] && [ -n "$kexp" ]; then
      printf '%s' "$bexp" | b64dec > "$WORK/v.bin" 2>/dev/null
      dd if="$WORK/v.bin" of="$WORK/v.iv" bs=16 count=1 2>/dev/null
      dd if="$WORK/v.bin" of="$WORK/v.ct" bs=16 skip=1 2>/dev/null
      local viv plain
      viv=$(bin2hex < "$WORK/v.iv")
      if plain=$(aes_cbc_dec "$kexp" "$viv" < "$WORK/v.ct" 2>/dev/null | gzip -dc 2>/dev/null) && [ -n "$plain" ]; then
        if [ -n "$xdev" ] && printf '%s' "$plain" | grep -qF "$xdev"; then
          pass=$((pass + 1)); printf '  ✓ 向量#%d 金标密文解开，deviceId=%s\n' "$n" "$xdev"
        else
          fail=$((fail + 1)); printf '  ✗ 向量#%d 解开了但 deviceId 不符\n' "$n"
        fi
      else
        fail=$((fail + 1)); printf '  ✗ 向量#%d 解金标密文失败\n' "$n"
      fi
    fi

    # ---- 3. 自加密 → 自解密 回环
    local eiv rt
    eiv=$(rand_hex 16)
    rt=$(printf '{"ok":1}' | gzip -n -c | aes_cbc_enc "$kexp" "$eiv" | aes_cbc_dec "$kexp" "$eiv" | gzip -dc 2>/dev/null)
    if [ "$rt" = '{"ok":1}' ]; then
      pass=$((pass + 1)); printf '  ✓ 向量#%d 自加密回环\n' "$n"
    else
      fail=$((fail + 1)); printf '  ✗ 向量#%d 自加密回环失败\n' "$n"
    fi
  done < "$WORK/vec.txt"

  # ---- 4. cookie 向量（AES-128-ECB）
  if [ -n "$cookie_cipher" ] && [ -n "$cookie_plain" ]; then
    local chex cgot
    chex=$(printf '%s' "$cookie_key" | bin2hex)
    cgot=$(printf '%s' "$cookie_cipher" | b64dec | aes_ecb_dec128 "$chex" 2>/dev/null)
    if [ "$cgot" = "$cookie_plain" ]; then
      pass=$((pass + 1)); printf '  ✓ cookie 向量解密一致\n'
    else
      fail=$((fail + 1))
      printf '  ✗ cookie 向量不符\n    期望 %s\n    实际 %s\n' "$cookie_plain" "$cgot"
    fi
  fi

  # ---- 5. gzip 回环
  local probe roundtrip
  probe='tangxin gzip roundtrip 0123456789'
  roundtrip=$(printf '%s' "$probe" | gzip -n -c | gzip -dc)
  if [ "$roundtrip" = "$probe" ]; then
    pass=$((pass + 1)); printf '  ✓ gzip 回环\n'
  else
    fail=$((fail + 1)); printf '  ✗ gzip 回环失败\n'
  fi

  # ---- 6. uuid
  local u
  u=$(uuid4)
  if [ ${#u} -eq 36 ]; then
    pass=$((pass + 1)); printf '  ✓ uuid 形状 (%s)\n' "$u"
  else
    fail=$((fail + 1)); printf '  ✗ uuid 形状异常: %s\n' "$u"
  fi

  printf '\n通过 %d 项' "$pass"
  if [ "$fail" -eq 0 ]; then
    printf '，全部一致 ✓\n'
    return 0
  fi
  printf '，失败 %d 项 ✗\n' "$fail"
  return 1
}

cmd_info() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  bootstrap

  printf '── 会话 ──\n'
  printf '  user_id  : %s\n' "${P_UID:--}"
  printf '  nickname : %s\n' "${P_NAME:--}"
  printf '  is_vip   : %s\n' "${P_VIP:--}"
  printf '  has_login: %s\n' "${P_LOGIN:--}"
  printf '  token    : %s\n' "${P_TOKEN:--}"
  printf '  deviceId : %s\n' "$P_DEVICE"

  local cdn
  cdn=$(cdn_probe)
  if [ "$cdn" = "ok" ]; then
    printf '── 镜像 ──\n  国内 CDN 直连可用\n'
  else
    printf '── 镜像 ──\n  国内 CDN 被劫持 → 走 CloudFront 镜像\n'
  fi

  printf '\n'
  api_call "$WORK/sys.json" "/system/info" '{"channel_code":null,"share_code":null}'
  local title imgkey domains
  title=$(json_str "$WORK/sys.json" 'site_title' | unescape_unicode)
  imgkey=$(json_str "$WORK/sys.json" 'img_key')
  domains=$(tr -d '\n' < "$WORK/sys.json" | grep -o '"domain":"[^"]*"' | sed 's/.*:"//;s/"$//' | tr '\n' ' ')
  printf '── 站点 ──\n'
  printf '  标题    : %s\n' "${title:--}"
  printf '  img_key : %s\n' "${imgkey:--}"
  printf '  域名    : %s\n' "${domains:--}"
}

cmd_cdn() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  local r
  r=$(cdn_probe)
  if [ "$r" = "ok" ]; then
    printf '国内域名 whk.srslpoh.cn : ✓ 可用（直连）\n'
  else
    printf '国内域名 whk.srslpoh.cn : ✗ 被劫持/不可达 → 自动走 CloudFront\n'
  fi
}

cmd_call() {
  local path="${1:-}" data="${2:-{\}}"
  [ -n "$path" ] || die "用法: txin.sh call <path> ['json']"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  api_call "$WORK/out.json" "$path" "$data"
  pretty "$WORK/out.json"
}

cmd_list() {
  local page="${1:-1}" cat="${2:-1}"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  api_call "$WORK/list.json" "/movie/home" "{\"cat_id\":\"$cat\",\"page\":$page}"

  perl -MJSON::PP -Mutf8 -CS -e '
    local $/; my $d = JSON::PP->new->decode(<STDIN>);
    my @blocks = @{ $d->{data}{data} // [] };
    my $total = 0;
    for my $b (@blocks) {
      my @items = @{ $b->{items} // [] };
      $total += scalar @items;
      printf "\n【%s】%s\n", ($b->{name} // "-"), ($b->{intro} // "");
      for my $m (@items) {
        my $tag = (($m->{pay_type} // "") eq "vip") ? "VIP" : "   ";
        printf "  %s %-9s %-46s %s\n",
          $tag, ($m->{id} // "-"), ($m->{name} // "-"), ($m->{duration} // "-");
      }
    }
    printf "\n共 %d 条（第 %s 页）\n", $total, ($d->{data}{current_page} // "1");
  ' < "$WORK/list.json"
}

cmd_detail() {
  local id="${1:-}"
  [ -n "$id" ] || die "用法: txin.sh detail <id>"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  api_call "$WORK/d.json" "/movie/detail" "{\"id\":\"$id\"}"

  perl -MJSON::PP -Mutf8 -CS -e '
    local $/; my $d = JSON::PP->new->decode(<STDIN>);
    my $m = $d->{data};
    if (!$m) { printf "无数据: %s\n", ($d->{error} // "-"); exit 2 }
    printf "标题 : %s\n", ($m->{name} // "-");
    printf "分类 : %s\n", ($m->{category}{name} // "-");
    printf "付费 : %s / %s\n", ($m->{pay_type} // "-"), ($m->{layer_type} // "-");
    printf "时长 : %s\n", ($m->{duration} // "-");
    printf "播放 : %s    收藏 : %s\n", ($m->{click} // "-"), ($m->{favorite} // "-");
    printf "封面 : %s\n", ($m->{img} // "-");
    my @l = @{ $m->{play_links} // [] };
    print "线路 :\n";
    my $i = 0;
    for my $x (@l) {
      $i++;
      printf "  [%d] %-8s %s\n", $i, ($x->{name} // "-"), ($x->{m3u8_url} // "-");
    }
    print "  （后端不鉴权，游客直接可取）\n" if $i > 0 && (($m->{pay_type} // "") eq "vip");
  ' < "$WORK/d.json"
}

cmd_dl() {
  local id="" outdir="$HOME/Movies/txin" line=1
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--out)  outdir="$2"; shift 2 ;;
      -l|--line) line="$2";   shift 2 ;;
      *)         id="$1";     shift ;;
    esac
  done
  [ -n "$id" ] || die "用法: txin.sh dl <id> [-o 目录] [-l 线路号]"

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  api_call "$WORK/d.json" "/movie/detail" "{\"id\":\"$id\"}"

  local name m3u8
  name=$(perl -MJSON::PP -Mutf8 -CS -e '
    local $/; my $d = JSON::PP->new->decode(<STDIN>);
    print $d->{data}{name} // "";' < "$WORK/d.json")
  m3u8=$(perl -MJSON::PP -e '
    local $/; my $d = JSON::PP->new->decode(<STDIN>);
    my $n = shift // 1;
    my @l = @{ $d->{data}{play_links} // [] };
    print(($l[$n-1]{m3u8_url} // ""), "\n");' "$line" < "$WORK/d.json")

  [ -n "$m3u8" ] || die "拿不到第 $line 条线路的 m3u8（该视频可能只有 $(\
      perl -MJSON::PP -e 'local $/;my $d=JSON::PP->new->decode(<STDIN>);print scalar @{$d->{data}{play_links}//[]}' < "$WORK/d.json") 条）"

  case "$m3u8" in
    http*) FULL="$m3u8" ;;
    /*)    FULL="$HOST$m3u8" ;;
    *)     FULL="$HOST/$m3u8" ;;
  esac

  say "标题：${name:-$id}"
  say "m3u8：$FULL"

  if ! curl -sS -H "User-Agent: $UA" -H "Referer: $HOST/" "$FULL" -o "$WORK/p.m3u8" 2>/dev/null; then
    die "拉取播放列表失败"
  fi
  grep -q '#EXTM3U' "$WORK/p.m3u8" || die "不是合法 m3u8（可能被拦截）"

  local keyuri iv keyhex total
  keyuri=$(grep -o 'URI="[^"]*"' "$WORK/p.m3u8" | head -1 | sed 's/URI="//;s/"$//')
  iv=$(grep -o 'IV=0x[0-9a-fA-F]*' "$WORK/p.m3u8" | head -1 | sed 's/IV=0x//')

  if [ -n "$keyuri" ]; then
    keyuri=$(printf '%s' "$keyuri" | cdn_rewrite)
    curl -sS -H "User-Agent: $UA" -H "Referer: $HOST/" "$keyuri" -o "$WORK/enc.key" 2>/dev/null \
      || die "取密钥失败"
    local ksz
    ksz=$(wc -c < "$WORK/enc.key" 2>/dev/null | tr -d ' ')
    [ "${ksz:-0}" = "16" ] || die "密钥长度 ${ksz:-0} 字节（应为 16），可能被劫持成 HTML"
    keyhex=$(bin2hex < "$WORK/enc.key")
    say "密钥：$keyhex  IV：${iv:-0}"
  else
    keyhex=""
    warn "播放列表未加密"
  fi
  [ -n "$iv" ] || iv="00000000000000000000000000000000"

  mkdir -p "$outdir/$id" || die "无法创建目录 $outdir/$id"
  local tsfile="$outdir/$id/$id.ts"
  : > "$tsfile"

  grep -v '^#' "$WORK/p.m3u8" | grep -v '^[[:space:]]*$' > "$WORK/segs.txt"
  total=$(wc -l < "$WORK/segs.txt" | tr -d ' ')
  say "分片：$total  加密：$( [ -n "$keyhex" ] && echo AES-128 || echo 无 )"

  local i=0 seg SU
  while IFS= read -r seg; do
    i=$((i + 1))
    case "$seg" in
      http*) SU="$seg" ;;
      /*)    SU="$HOST$seg" ;;
      *)     SU="$HOST/$seg" ;;
    esac
    SU=$(printf '%s' "$SU" | cdn_rewrite)

    printf '\r  下载 %d/%d' "$i" "$total" >&2
    if [ -n "$keyhex" ]; then
      curl -sS -H "User-Agent: $UA" -H "Referer: $HOST/" "$SU" 2>/dev/null \
        | aes_cbc_dec_nopad "$keyhex" "$iv" >> "$tsfile" 2>/dev/null
    else
      curl -sS -H "User-Agent: $UA" -H "Referer: $HOST/" "$SU" >> "$tsfile" 2>/dev/null
    fi
  done < "$WORK/segs.txt"
  printf '\n' >&2

  local sz first
  sz=$(wc -c < "$tsfile" | tr -d ' ')
  first=$(dd if="$tsfile" bs=1 count=1 2>/dev/null | bin2hex)
  say "完成：$tsfile"
  printf '  大小：%s MB\n' "$(perl -e "printf '%.2f', $sz/1048576")"
  if [ "$first" = "47" ]; then
    printf '  校验：首字节 0x47 ✓ 合法 MPEG-TS\n'
  else
    warn "首字节是 0x${first:-??}，不是 0x47 —— 可能解密有误"
  fi
  printf '  转 mp4：ffmpeg -i "%s" -c copy "%s"\n' "$tsfile" "${tsfile%.ts}.mp4"
}

cmd_menu() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/txin.XXXXXX")
  while :; do
    printf '\n'
    printf '  \033[1;36m糖心客户端\033[0m  %s\n' "$HOST"
    printf '  ────────────────────────────\n'
    printf '  1) 会话与站点信息\n'
    printf '  2) 浏览视频列表\n'
    printf '  3) 查看作品详情\n'
    printf '  4) 下载作品\n'
    printf '  5) CDN 诊断\n'
    printf '  6) 协议自检\n'
    printf '  0) 退出\n'
    printf '  选择: '
    IFS= read -r opt || break
    case "$opt" in
      1) cmd_info ;;
      2) printf '页码(默认1): '; IFS= read -r pg; cmd_list "${pg:-1}" 1 ;;
      3) printf '作品 ID: '; IFS= read -r vid; [ -n "$vid" ] && cmd_detail "$vid" ;;
      4) printf '作品 ID: '; IFS= read -r vid
         [ -n "$vid" ] || continue
         printf '保存目录(默认 %s): ' "$HOME/Movies/txin"; IFS= read -r od
         cmd_dl "$vid" -o "${od:-$HOME/Movies/txin}" ;;
      5) cmd_cdn ;;
      6) cmd_selftest ;;
      0|q|"") break ;;
      *) printf '  无效选项\n' ;;
    esac
  done
  printf '\n'
}

usage() {
  cat <<'EOF'
txin.sh —— 糖心客户端（纯 shell，macOS 开箱即用）

用法:
  ./txin.sh selftest [向量文件]        协议金标校验（首次先跑这个）
  ./txin.sh info                       会话 / VIP / 镜像 / 站点信息
  ./txin.sh cdn                        探测国内 CDN 是否被劫持
  ./txin.sh call <path> ['json']       调任意接口
  ./txin.sh list [页] [分类]            视频列表
  ./txin.sh detail <id>                详情 + m3u8 线路
  ./txin.sh dl <id> [-o 目录] [-l 线]   下载解密合并为 .ts

环境变量:
  TXIN_HOST   覆盖站点，默认 https://tangxgw.com

例子:
  ./txin.sh selftest
  ./txin.sh detail 309770
  ./txin.sh dl 309770 -o ~/Movies/txin
EOF
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    selftest) require_tools; cmd_selftest "$@" ;;
    info)     require_tools; cmd_info "$@" ;;
    cdn)      require_tools; cmd_cdn "$@" ;;
    call)     require_tools; cmd_call "$@" ;;
    list)     require_tools; cmd_list "$@" ;;
    detail)   require_tools; cmd_detail "$@" ;;
    dl)       require_tools; cmd_dl "$@" ;;
    menu|gui) require_tools; cmd_menu ;;
    ""|-h|--help|help) usage ;;
    *) die "未知命令：$cmd（试试 --help）" ;;
  esac
}

main "$@"
