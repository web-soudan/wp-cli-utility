#!/usr/bin/env bash
# local-reprint — Local のサイト設定を local-wp から読み取り、reprint pull を実行するラッパー
#
# About:
#   Local (by Flywheel) のサイトの wp-config.php から DB 情報 (DB_NAME / DB_USER / DB_PASSWORD / DB_HOST) を、
#   DB からサイト URL (home) を local-wp 経由で取得し、そのサイトに対して
#   reprint (https://developer.wordpress.org/reprint/) の pull を実行します。
#   reprint は Local の PHP / MySQL ソケットで動くよう、local-wp の中で実行されます。
#
# Usage:
#   local-reprint <site_name> <remote_url> [options] [-- <reprint の追加オプション>]
#   local-reprint --help
#
# Requires: /usr/local/bin/local-wp, curl
#           reprint.phar（無ければ初回実行時に WordPress.org から自動ダウンロード）
#
# 秘密鍵・state・reprint.phar は既定で app/reprint/ に置きます。
# app/public は Web の公開フォルダで、Live Link で外部に公開すると中のファイルを誰でも取得できるためです。
#
set -Eeuo pipefail

LOCAL_WP="${LOCAL_WP:-/usr/local/bin/local-wp}"
# 常に最新の安定版を返す配布 URL（https://github.com/WordPress/reprint#try-it-with-the-demo-site）
REPRINT_PHAR_URL="${REPRINT_PHAR_URL:-https://plugins.svn.wordpress.org/reprint/downloads/reprint.phar}"

usage() {
  cat <<'EOF'
Usage:
  local-reprint <site_name> <remote_url> [options] [-- <reprint pull の追加オプション>]

  Local のサイト <site_name> の wp-config.php と DB から接続情報とサイト URL を取得し、
  local-wp の中で reprint pull を実行します。
  --runtime=none --start-runtime=none は常に付きます（サイトは Local で表示するため）。

Arguments:
  site_name                「Local Sites/<site_name>」のフォルダ名（local-wp と同じ）
  remote_url               コピー元のサイト URL（Basic 認証があれば https://user:pass@example.com）

Options:
  --target-db=NAME         書き込み先 DB（既定: wp-config の DB_NAME）。存在しなければ作成します
  --target-user=USER       既定: wp-config の DB_USER
  --target-pass=PASS       既定: wp-config の DB_PASSWORD
  --target-host=HOST       既定: wp-config の DB_HOST（localhost ならソケット接続）
  --target-port=PORT       既定: DB_HOST に :port があればその値
  --new-site-url=URL       既定: wp option get home
  --private-key-path=PATH  reprint の秘密鍵（既定: コピー元ごとに app/reprint/reprint-key-<ホスト名>.pem）。
                           無ければ reprint keygen で作成し、コピー元に登録する Migration Token と
                           登録先 URL を表示します（対話実行なら登録後に Enter でそのまま pull します）。
                           --secret=TOKEN（接続トークン）を渡した場合は秘密鍵を使いません
  --phar=PATH              reprint.phar（既定: app/reprint/reprint.phar）
                           無ければ pull の前に REPRINT_PHAR_URL からダウンロードします
  --state-dir=DIR          既定: app/reprint/state
  --fs-root=DIR            既定: ./files

  相対パスは app/public 基準です。秘密鍵と state は app/public（Web の公開フォルダ）の外に置いてください。
  --no-link-wp-content     pull 後に app/public/wp-content を symlink にしない
                           （既定では、pull した wp-content への symlink にします。
                             既存の wp-content は wp-content.bak-<日時> にリネームして残します）
  -n, --dry-run            取得した値と実行するコマンドを表示するだけで終了
  -y, --yes                確認プロンプトを省略
  -h, --help               このヘルプを表示

  上記以外の --xxx と、-- 以降の引数は、そのまま reprint pull に渡します
  （例: --verbose, --exclude-host-plugins）。

Environment:
  LOCAL_WP                 local-wp のパス（既定: /usr/local/bin/local-wp）
  REPRINT_PHAR_URL         reprint.phar のダウンロード元
                           （既定: https://plugins.svn.wordpress.org/reprint/downloads/reprint.phar）

Examples:
  local-reprint mysite https://user:pass@example.com
  local-reprint mysite https://user:pass@example.com --phar=/path/to/reprint.phar
  local-reprint mysite https://example.com --target-db=reprint_copy --dry-run
EOF
}

die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "› $*" >&2; }
warn() { echo "⚠ $*" >&2; }

# URL 中の Basic 認証情報を伏せる
mask_url() { printf '%s' "$1" | sed -E 's#^(https?://)[^/@]+@#\1***@#'; }

# local-wp 経由で実行（.bashrc 等の stderr ノイズは捨てる）
lw() { "$LOCAL_WP" "$SITE" -- "$@" 2>/dev/null; }

# app/public 基準の相対パスを、ホスト上の絶対パスにする
abs_from_public() {
  if [[ "$1" == /* ]]; then printf '%s' "$1"; else printf '%s/%s' "$PUBLIC_DIR" "${1#./}"; fi
}

# JSON 1 行から "key":"value" の value を取り出す（\/ も戻す）
json_str() { printf '%s' "$2" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g'; }

# reprint.phar をダウンロードして $1（ホスト上の絶対パス）に置く。
# 同じフォルダの一時ファイルに落とし、Local の PHP で --version が通ってから差し替える。
download_phar() {
  local dest="$1" dir tmp ver
  local curl_opts=(-fL --retry 2)
  dir="$(dirname "$dest")"
  tmp="$dir/.reprint-download.$$.phar"

  info "reprint.phar が無いため、ダウンロードします: $REPRINT_PHAR_URL"
  mkdir -p "$dir" || die "保存先のフォルダを作成できませんでした: $dir"
  if [[ -t 2 ]]; then curl_opts+=(--progress-bar); else curl_opts+=(-sS); fi
  if ! curl "${curl_opts[@]}" -o "$tmp" "$REPRINT_PHAR_URL"; then
    rm -f "$tmp"
    die "reprint.phar をダウンロードできませんでした: ${REPRINT_PHAR_URL}（手動で取得して --phar=PATH で指定することもできます）"
  fi
  if ! ver="$(lw php "$tmp" --version)" || [[ -z "$ver" ]]; then
    rm -f "$tmp"
    die "ダウンロードした reprint.phar を Local の PHP で実行できませんでした（php reprint.phar --version が失敗）"
  fi
  mv -f "$tmp" "$dest"
  info "reprint.phar を保存しました: ${dest}（$(printf '%s' "$ver" | head -n 1)）"
}

# remote_url から鍵ファイル名に使うホスト名を取り出す（Basic 認証とパスは除き、ポートは残す）
remote_host() {
  local h="${1#*://}"
  h="${h%%[/?#]*}"
  h="${h##*@}"
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '_'
}

# コピー元の「ツール → Reprint Server」の URL（Basic 認証は除く）
reprint_admin_url() {
  local u
  u="$(printf '%s' "$1" | sed -E 's|^(https?://)[^/@]+@|\1|; s|[?#].*$||; s|/+$||')"
  printf '%s/wp-admin/tools.php?page=reprint-server' "$u"
}

# 秘密鍵から Migration Token（公開鍵の DER を base64 にしたもの）を作り直す
token_from_key() {
  command -v openssl >/dev/null 2>&1 || return 0
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | base64 | tr -d '\n'
}

# 秘密鍵から Migration Token ID（公開鍵の DER の sha256 の先頭 16 桁。Reprint Server の一覧に出る ID）を求める
key_id_from_key() {
  command -v openssl >/dev/null 2>&1 || return 0
  openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | shasum -a 256 2>/dev/null | cut -c1-16
}

# reprint の API URL（reprint pull はサイト URL に ?reprint-api を自動で付けるが、preflight コマンドは付けない）
reprint_api_url() {
  case "$1" in
    *[?\&]reprint-api*|*[?\&]site-export-api*) printf '%s' "$1" ;;
    *\?*) printf '%s&reprint-api' "$1" ;;
    *)    printf '%s?reprint-api' "$1" ;;
  esac
}

# コピー元に秘密鍵が登録されているかを reprint preflight で確かめる。
# 0: 通過 / 2: 未登録（AUTH_NOT_CONFIGURED・AUTH_UNKNOWN_KEY）/ 1: それ以外の失敗（原因は pull のエラー表示に任せる）
# ※ --private-key-path を渡すと、未登録でも reprint pull は exit 4 ではなく exit 1 で終わるため、事前に確かめる。
#   pull の state は使わず、確認用の一時フォルダを使って最後に消す。preflight の結果が pull の state に残ると、
#   pull が自分の接続確認を飛ばしてその結果を使い回すため
check_enrolled() {
  local out code dir a rc=0
  local opts=()
  dir="${STATE_DIR%/}-enroll-check"
  for a in ${PASSTHRU[@]+"${PASSTHRU[@]}"}; do [[ "$a" == --insecure ]] && opts+=(--insecure); done
  out="$(lw php "$PHAR" preflight "$(reprint_api_url "$REMOTE")" --state-dir="$dir" --fs-root="$FS_ROOT" \
         --private-key-path="$KEY_PATH" ${opts[@]+"${opts[@]}"})" || rc=$?
  rm -rf "$(abs_from_public "$dir")"
  [[ $rc -eq 0 ]] && return 0
  code="$(printf '%s\n' "$out" | grep -o '"error_code":"[A-Z_]*"' | tail -n 1 | sed 's/.*:"//; s/"$//')" || code=""
  case "$code" in
    AUTH_NOT_CONFIGURED|AUTH_UNKNOWN_KEY) return 2 ;;
  esac
  return 1
}

# Migration Token と登録手順を表示し、macOS ならクリップボードにもコピーする
show_enroll_guide() {
  local token="$1" key_id="${2:-}"
  cat >&2 <<EOF

  ── コピー元に Migration Token を登録してください ─────────────────
  1. $(reprint_admin_url "$REMOTE") を開く（ツール → Reprint Server）
  2. 下の Migration Token を貼り付けて「Authorize client」を押す
  秘密鍵: ${KEY_FILE}${key_id:+  (Migration Token ID: ${key_id})}

${token}

EOF
  if command -v pbcopy >/dev/null 2>&1 && printf '%s' "$token" | pbcopy 2>/dev/null; then
    info "Migration Token をクリップボードにコピーしました"
  fi
}

# 登録を待つ。対話実行なら Enter で続行して 0 を返し、それ以外は再実行を案内して 1 を返す
wait_for_enroll() {
  if [[ -t 0 && $ASSUME_YES -ne 1 ]]; then
    printf '登録したら Enter を押してください（中止: Ctrl+C）' >&2
    read -r _ || return 1
    return 0
  fi
  warn "登録後、同じコマンドを再実行してください（作成済みの秘密鍵をそのまま使います）。"
  return 1
}

# reprint keygen で秘密鍵を作り、Migration Token を表示する
create_key() {
  local out token key_id err
  info "秘密鍵が無いため作成します: ${KEY_FILE}"
  mkdir -p "$(dirname "$KEY_FILE")" || die "秘密鍵の保存先フォルダを作成できませんでした: $(dirname "$KEY_FILE")"
  out="$(lw php "$PHAR" keygen "$REMOTE" --state-dir="$STATE_DIR" --out="$KEY_PATH" --progress=jsonl \
         | grep '"reprint_report"' | tail -n 1)" || true
  token="$(json_str public_key "$out")"
  key_id="$(json_str key_id "$out")"
  if [[ -z "$token" || ! -f "$KEY_FILE" ]]; then
    err="$(json_str error "$out")"
    die "秘密鍵を作成できませんでした${err:+: ${err}}"
  fi
  chmod 600 "$KEY_FILE" 2>/dev/null || warn "秘密鍵のパーミッションを 600 にできませんでした: $KEY_FILE"
  info "秘密鍵を作成しました"
  show_enroll_guide "$token" "$key_id"
}

# fs-root 内の wp-content を指す symlink のパス（fs-root が相対なら app/public からの相対パス）
link_target_for() {
  local root="${FS_ROOT%/}"
  root="${root#./}"
  printf '%s%s' "$root" "$1"
}

# app/public/wp-content を、pull した wp-content への symlink にする。
# 既存の実ディレクトリや別の symlink は wp-content.bak-<日時> にリネームして残す。
link_wp_content() {
  local target link backup
  target="$(link_target_for "$1")"
  link="$PUBLIC_DIR/wp-content"

  if [[ "$target" == /* ]]; then
    [[ -d "$target" ]] || { warn "pull した wp-content が見つかりません: $target"; return 1; }
  else
    [[ -d "$PUBLIC_DIR/$target" ]] || { warn "pull した wp-content が見つかりません: $PUBLIC_DIR/$target"; return 1; }
  fi

  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    info "wp-content は既に symlink です（-> ${target}）"
    return 0
  fi
  if [[ -e "$link" || -L "$link" ]]; then
    backup="$link.bak-$(date +%Y%m%d-%H%M%S)"
    mv "$link" "$backup"
    info "既存の wp-content を $(basename "$backup") にリネームしました"
  fi
  ln -s "$target" "$link"
  info "wp-content を symlink にしました（wp-content -> ${target}）"
}

# ---- 引数解析 -------------------------------------------------------------
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ $# -ge 2 ]] || { usage >&2; exit 1; }

SITE="$1"; REMOTE="$2"; shift 2
[[ "$REMOTE" =~ ^https?:// ]] || die "remote_url は http(s):// で始めてください: $REMOTE"
# reprint は URL の文字列から state 内の記録の場所（remotes/<URL の md5>）を決めるため、
# 末尾の / の有無だけで別のサイト扱いになり、前回の続きから同期できなくなる。表記をそろえるため取り除く
while [[ "$REMOTE" == */ ]]; do REMOTE="${REMOTE%/}"; done

OPT_DB=""; OPT_USER=""; OPT_PASS=""; OPT_PASS_SET=0; OPT_HOST=""; OPT_PORT=""; OPT_URL=""
# PHAR・STATE_DIR・KEY_PATH の既定値は app/public の場所が分かってから決める（app/reprint/ 配下）
KEY_PATH=""; PHAR=""; STATE_DIR=""; FS_ROOT="./files"
DRY_RUN=0; ASSUME_YES=0; LINK_WP_CONTENT=1
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-db=*)        OPT_DB="${1#*=}" ;;
    --target-user=*)      OPT_USER="${1#*=}" ;;
    --target-pass=*)      OPT_PASS="${1#*=}"; OPT_PASS_SET=1 ;;
    --target-host=*)      OPT_HOST="${1#*=}" ;;
    --target-port=*)      OPT_PORT="${1#*=}" ;;
    --new-site-url=*)     OPT_URL="${1#*=}" ;;
    --private-key-path=*) KEY_PATH="${1#*=}" ;;
    --phar=*)             PHAR="${1#*=}" ;;
    --state-dir=*)        STATE_DIR="${1#*=}" ;;
    --fs-root=*)          FS_ROOT="${1#*=}" ;;
    --target-engine=*)    [[ "${1#*=}" == "mysql" ]] || die "このスクリプトは --target-engine=mysql 専用です" ;;
    --no-link-wp-content) LINK_WP_CONTENT=0 ;;
    -n|--dry-run)         DRY_RUN=1 ;;
    -y|--yes)             ASSUME_YES=1 ;;
    -h|--help)            usage; exit 0 ;;
    --)                   shift; PASSTHRU+=("$@"); break ;;
    *)                    PASSTHRU+=("$1") ;;
  esac
  shift
done

# --secret（接続トークン）を reprint に渡す場合は秘密鍵を扱わない
USE_SECRET=0
for a in ${PASSTHRU[@]+"${PASSTHRU[@]}"}; do
  if [[ "$a" == --secret || "$a" == --secret=* ]]; then USE_SECRET=1; fi
done
[[ $USE_SECRET -eq 1 && -n "$KEY_PATH" ]] && die "--private-key-path と --secret は同時に指定できません"
[[ $USE_SECRET -eq 1 || -n "$(remote_host "$REMOTE")" ]] || die "remote_url からホスト名を取り出せません: $(mask_url "$REMOTE")"

[[ -x "$LOCAL_WP" ]] || die "local-wp が見つかりません: ${LOCAL_WP}（環境変数 LOCAL_WP で指定できます）"

# ---- Local のサイト情報を取得 -------------------------------------------
info "local-wp ($SITE) から DB 情報とサイト URL を取得しています..."

# 1 回の local-wp 呼び出しでまとめて取得する（1 行 1 値。取得できなかった値は __ERR__）
# shellcheck disable=SC2016  # $k は local-wp 内の bash で展開させる
RAW="$(lw bash -c '
  pwd
  for k in DB_NAME DB_USER DB_PASSWORD DB_HOST table_prefix; do
    v="$(wp config get "$k" 2>/dev/null)" && printf "%s\n" "$v" || echo __ERR__
  done
  e="$(mktemp)"
  v="$(wp option get home --skip-plugins --skip-themes 2>"$e")" && printf "%s\n" "$v" || echo __ERR__
  grep -m1 "Error" "$e" | tr -d "\r"
  rm -f "$e"
')" || true

{
  IFS= read -r PUBLIC_DIR   || true
  IFS= read -r CFG_DB       || true
  IFS= read -r CFG_USER     || true
  IFS= read -r CFG_PASS     || true
  IFS= read -r CFG_HOST     || true
  IFS= read -r CFG_PREFIX   || true
  IFS= read -r CFG_HOME     || true
  IFS= read -r HOME_ERR     || true   # home を取得できなかったときの wp のエラー（1 行）
} <<< "$RAW"

[[ -n "${PUBLIC_DIR:-}" && -d "$PUBLIC_DIR" ]] \
  || die "local-wp でサイト「${SITE}」に入れませんでした。Local でサイトを起動し、一度「Open Site Shell」を実行してください。"
for v in CFG_DB CFG_USER CFG_HOST; do
  [[ "${!v:-__ERR__}" != "__ERR__" ]] || die "wp-config.php から ${v#CFG_} を取得できませんでした（$PUBLIC_DIR/wp-config.php を確認してください）"
done
[[ "${CFG_PASS:-__ERR__}" != "__ERR__" ]] || CFG_PASS=""
# DB に繋がらないと pull もできないので、--new-site-url の有無に関わらずここで止める
if [[ "${HOME_ERR:-}" == *データベース接続* || "${HOME_ERR:-}" == *"database connection"* ]]; then
  die "サイト「${SITE}」の DB に接続できません（${HOME_ERR}）。Local でサイトが起動しているか確認してください。"
fi
# 秘密鍵・state・reprint.phar の既定の置き場所。
# app/public は Web の公開フォルダで、Live Link で外部公開すると秘密鍵を取得されるため、その一つ上の app/reprint に置く
REPRINT_DIR="$(dirname "$PUBLIC_DIR")/reprint"
[[ -n "$PHAR" ]]      || PHAR="$REPRINT_DIR/reprint.phar"
[[ -n "$STATE_DIR" ]] || STATE_DIR="$REPRINT_DIR/state"

# reprint.phar のホスト上の絶対パス（無ければ確認後にダウンロードする）
PHAR_PATH="$(abs_from_public "$PHAR")"
PHAR_MISSING=0
[[ -f "$PHAR_PATH" ]] || PHAR_MISSING=1

# 秘密鍵（既定はコピー元ごとに app/reprint/reprint-key-<ホスト名>.pem）。無ければ確認後に作成する
KEY_FILE=""; KEY_MISSING=0
if [[ $USE_SECRET -eq 1 ]]; then
  KEY_LABEL="使わない（--secret の接続トークンで認証）"
else
  [[ -n "$KEY_PATH" ]] || KEY_PATH="$REPRINT_DIR/reprint-key-$(remote_host "$REMOTE").pem"
  KEY_FILE="$(abs_from_public "$KEY_PATH")"
  KEY_LABEL="$KEY_FILE"
  if [[ ! -f "$KEY_FILE" ]]; then
    KEY_MISSING=1
    KEY_LABEL+="  ※ 無いため作成します（コピー元で Migration Token の登録が必要）"
  fi
fi

# ---- 接続先を決める -----------------------------------------------------
TARGET_DB="${OPT_DB:-$CFG_DB}"
TARGET_USER="${OPT_USER:-$CFG_USER}"
if [[ $OPT_PASS_SET -eq 1 ]]; then TARGET_PASS="$OPT_PASS"; else TARGET_PASS="$CFG_PASS"; fi

# DB_HOST は "host" / "host:port" / "host:/path/to.sock" のいずれか
TARGET_HOST="$CFG_HOST"; TARGET_PORT=""
if [[ "$CFG_HOST" == *:* ]]; then
  TARGET_HOST="${CFG_HOST%%:*}"
  rest="${CFG_HOST#*:}"
  if [[ "$rest" =~ ^[0-9]+$ ]]; then
    TARGET_PORT="$rest"
  else
    warn "DB_HOST のソケット指定 ($rest) は reprint に渡せないため、PHP の既定ソケットを使います"
  fi
fi
[[ -n "$OPT_HOST" ]] && TARGET_HOST="$OPT_HOST"
[[ -n "$OPT_PORT" ]] && TARGET_PORT="$OPT_PORT"

if [[ -n "$OPT_URL" ]]; then
  NEW_URL="$OPT_URL"
elif [[ "${CFG_HOME:-__ERR__}" != "__ERR__" && -n "$CFG_HOME" ]]; then
  NEW_URL="$CFG_HOME"
else
  die "サイト URL (home) を DB から取得できませんでした${HOME_ERR:+（${HOME_ERR}）}。--new-site-url=http://<site>.local を指定してください。"
fi

[[ "$TARGET_DB" =~ ^[A-Za-z0-9_]+$ ]] || die "DB 名に使えない文字が含まれています: $TARGET_DB"

# ---- 実行するコマンド ---------------------------------------------------
CMD=(php "$PHAR" pull "$REMOTE"
  --state-dir="$STATE_DIR" --fs-root="$FS_ROOT"
  --target-engine=mysql --target-host="$TARGET_HOST"
  --target-db="$TARGET_DB" --target-user="$TARGET_USER" --target-pass="$TARGET_PASS"
  --new-site-url="$NEW_URL"
  --runtime=none --start-runtime=none)
[[ -n "$TARGET_PORT" ]] && CMD+=(--target-port="$TARGET_PORT")
[[ -n "$KEY_PATH"    ]] && CMD+=(--private-key-path="$KEY_PATH")
CMD+=(${PASSTHRU[@]+"${PASSTHRU[@]}"})

# 表示用（パスワードと Basic 認証は伏せる）
show_cmd() {
  local a out=""
  for a in "${CMD[@]}"; do
    case "$a" in
      --target-pass=*)    out+="--target-pass=*** " ;;
      --secret=*)         out+="--secret=*** " ;;
      http://*|https://*) out+="$(mask_url "$a") " ;;
      *)                  out+="$(printf '%q' "$a") " ;;
    esac
  done
  printf '  local-wp %q -- %s\n' "$SITE" "${out% }"
}

cat >&2 <<EOF

  サイト       : $SITE  ($PUBLIC_DIR)
  コピー元     : $(mask_url "$REMOTE")
  書き込み先 DB: $TARGET_DB  (user=$TARGET_USER host=$TARGET_HOST${TARGET_PORT:+ port=$TARGET_PORT})$( [[ "$TARGET_DB" != "$CFG_DB" ]] && printf '  ※ wp-config の DB_NAME は %s' "$CFG_DB" )
  新しい URL   : $NEW_URL
  ファイル     : $FS_ROOT  (state: $STATE_DIR)
  reprint.phar : $PHAR_PATH$( [[ $PHAR_MISSING -eq 1 ]] && printf '  ※ 無いため実行時にダウンロードします' )
  秘密鍵       : ${KEY_LABEL}
  wp-content   : $( [[ $LINK_WP_CONTENT -eq 1 ]] && echo "pull 後に $FS_ROOT 内の wp-content への symlink にする（既存の実ディレクトリは wp-content.bak-<日時> に退避）" || echo "変更しない" )

EOF
show_cmd >&2
echo >&2

# 以前の既定（app/public 直下）に置いた秘密鍵・state・reprint.phar が残っていれば、移すよう案内する。
# 公開フォルダに残ると Web から取得されるうえ、移さないと鍵の登録と pull を最初からやり直すことになるため
OLD_PATHS=("$PUBLIC_DIR/state" "$PUBLIC_DIR/reprint.phar")
NEW_PATHS=("$STATE_DIR" "$PHAR_PATH")
if [[ -n "$KEY_FILE" ]]; then
  OLD_PATHS+=("$PUBLIC_DIR/reprint-key-$(remote_host "$REMOTE").pem")
  NEW_PATHS+=("$KEY_FILE")
fi
for i in "${!OLD_PATHS[@]}"; do
  old="${OLD_PATHS[$i]}"; new="${NEW_PATHS[$i]}"
  [[ -e "$old" && "$old" != "$new" ]] || continue
  warn "以前の既定の場所（Web の公開フォルダ内）に残っています: $old"
  if [[ ! -e "$new" ]]; then
    warn "  引き継ぐなら、実行前に移してください: mkdir -p $(printf '%q' "$(dirname "$new")") && mv $(printf '%q' "$old") $(printf '%q' "$new")"
  elif [[ "$old" == "$PUBLIC_DIR/state" ]] && ! ls "$new"/remotes/*/local_index.jsonl >/dev/null 2>&1; then
    # 新しい state にはファイル取得の記録が無い（鍵の確認で止まった等）。古い state を消すと fs-root を最初から取り直すことになる
    warn "  前回の pull の記録です。削除すると $FS_ROOT のファイルを最初から取り直すことになります。"
    warn "  続きから同期するなら、新しい state と入れ替えてください: rm -rf $(printf '%q' "$new") && mv $(printf '%q' "$old") $(printf '%q' "$new")"
  else
    warn "  不要なら削除してください: rm -rf $(printf '%q' "$old")"
  fi
done

if [[ $DRY_RUN -eq 1 ]]; then
  info "--dry-run のため実行しません"
  exit 0
fi

if [[ $ASSUME_YES -ne 1 ]]; then
  [[ -t 0 ]] || die "確認が必要です。非対話で実行する場合は --yes を付けてください。"
  printf 'DB「%s」の同名テーブルはコピー元の内容で上書きされます。続行しますか? [y/N] ' "$TARGET_DB" >&2
  read -r ans
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]] || { info "中止しました"; exit 1; }
fi

# app/reprint は自分だけが読めるようにする（秘密鍵と state を置くため）
if [[ ! -d "$REPRINT_DIR" ]]; then
  if ! { mkdir -p "$REPRINT_DIR" && chmod 700 "$REPRINT_DIR"; }; then
    die "フォルダを作成できませんでした: $REPRINT_DIR"
  fi
fi

# 初回実行時など reprint.phar が無ければ取得する
[[ $PHAR_MISSING -eq 1 ]] && download_phar "$PHAR_PATH"

# 秘密鍵が無ければ作成し、コピー元への登録を待つ。
# 既存の鍵でも未登録（登録の取り消し・別の鍵への差し替えなど）なら、Migration Token を出し直して登録を待つ
if [[ -n "$KEY_FILE" ]]; then
  if [[ $KEY_MISSING -eq 1 ]]; then
    create_key
    wait_for_enroll || exit 4
  fi
  while :; do
    info "コピー元に秘密鍵が登録されているか確認しています..."
    enrolled=0; check_enrolled || enrolled=$?
    [[ $enrolled -eq 2 ]] || break
    warn "この秘密鍵はコピー元に登録されていません: $KEY_FILE"
    token="$(token_from_key "$KEY_FILE")" || token=""
    if [[ -z "$token" ]]; then
      # reprint pull のエラーにも Migration Token が表示されるので、そちらで登録してもらう
      warn "openssl が無いため Migration Token を表示できません。続く reprint のエラーに表示される Migration Token を登録してください。"
      break
    fi
    key_id="$(key_id_from_key "$KEY_FILE")" || key_id=""
    show_enroll_guide "$token" "$key_id"
    wait_for_enroll || exit 4
  done
fi

# wp-config と別の DB を使う場合は、無ければ作る（既存 DB には何もしない）
if [[ "$TARGET_DB" != "$CFG_DB" ]]; then
  info "DB「${TARGET_DB}」が無ければ作成します..."
  lw mysql -u"$TARGET_USER" -p"$TARGET_PASS" -h "$TARGET_HOST" ${TARGET_PORT:+-P "$TARGET_PORT"} \
    -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
    || die "DB「${TARGET_DB}」を作成できませんでした（ユーザー $TARGET_USER の権限を確認してください）"
fi

# ---- pull 実行 ----------------------------------------------------------
# 鍵の登録は上で確かめ済み（--private-key-path を渡すと reprint は鍵を自動作成せず、exit 4 も返さない）
status=0
"$LOCAL_WP" "$SITE" -- "${CMD[@]}" || status=$?

if [[ $status -ne 0 ]]; then
  # fs-root にファイルがあるのに state に取得の記録が無いと、再実行しても同じところで止まるため、対処を案内する
  if grep -q 'Filesystem root is not empty and no cursor found' "$(abs_from_public "$STATE_DIR")/progress.json" 2>/dev/null; then
    warn "reprint pull が失敗しました (exit $status)。"
    warn "${FS_ROOT} に以前 pull したファイルがありますが、state（${STATE_DIR}）にこの URL での取得の記録がありません。"
    warn "  前回の state が残っていれば ${STATE_DIR} に置き、前回と同じ URL で実行すると続きから同期できます。"
    warn "  最初から取り直す場合は、削除してから再実行してください: rm -rf $(printf '%q' "$(abs_from_public "$FS_ROOT")")"
    exit "$status"
  fi
  warn "reprint pull が失敗しました (exit $status)。同じコマンドを再実行すると続きから再開します。"
  warn "Plugin 'mysql_native_password' is not loaded が出た場合、そのユーザー ($TARGET_USER) が MySQL に存在しない可能性があります。"
  exit "$status"
fi

# ---- 後処理のヒント -----------------------------------------------------
META="$(lw php "$PHAR" pull-metadata "$REMOTE" --state-dir="$STATE_DIR" | head -n 1)" || META=""
REMOTE_PREFIX="$(json_str tablePrefix "$META")"
CONTENT_DIR="$(json_str contentDirectory "$META")"

echo >&2
info "pull が完了しました"
if [[ -n "$REMOTE_PREFIX" && "$REMOTE_PREFIX" != "$CFG_PREFIX" ]]; then
  warn "テーブル接頭辞が違います（コピー元: $REMOTE_PREFIX / wp-config: ${CFG_PREFIX}）。サイトに反映するには:"
  printf '    local-wp %q -- wp config set table_prefix %q --type=variable\n' "$SITE" "$REMOTE_PREFIX" >&2
fi
if [[ "$TARGET_DB" != "$CFG_DB" ]]; then
  warn "wp-config の DB_NAME は「${CFG_DB}」のままです。サイトに反映するには:"
  printf '    local-wp %q -- wp config set DB_NAME %q\n' "$SITE" "$TARGET_DB" >&2
fi

# ---- wp-content を pull したディレクトリへの symlink にする ------------------
if [[ -z "$CONTENT_DIR" ]]; then
  warn "pull-metadata から wp-content の場所を取得できなかったため、symlink は作成しません"
elif [[ $LINK_WP_CONTENT -ne 1 ]]; then
  info "wp-content は ${FS_ROOT%/}${CONTENT_DIR} にあります（--no-link-wp-content のため symlink は作成しません）"
else
  link_wp_content "$CONTENT_DIR"
fi
