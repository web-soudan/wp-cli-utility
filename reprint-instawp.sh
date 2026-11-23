#!/usr/bin/env bash
# instawp-reprint — InstaWP のサイト設定を wp-cli で読み取り、reprint pull を実行するラッパー
#
# About:
#   InstaWP のサイトに SSH で入り、WordPress のフォルダで実行します。
#   wp-config.php から DB 情報 (DB_NAME / DB_USER / DB_PASSWORD / DB_HOST) を、
#   DB からサイト URL (siteurl) を wp-cli で取得し、そのサイトに対して
#   reprint (https://developer.wordpress.org/reprint/) の pull を実行します。
#   InstaWP のサイトは公開されているため、秘密鍵・state・reprint.phar は公開フォルダの外
#   （public_html と同じ階層の private/reprint。無ければ ~/reprint/<WordPress のフォルダから作った名前>）に置きます。
#   どちらにも書き込めない場合は、WordPress のフォルダ内に推測されにくい名前の作業フォルダ
#   （.reprint-work-<ランダム>）を作り、Web から読めないかを確認します。
#
# Usage:
#   instawp-reprint.sh <remote_url> [options] [-- <reprint の追加オプション>]
#   instawp-reprint.sh --help
#
# Requires: wp (WP-CLI), php, curl または wget
#           openssl（鍵の登録が必要になったとき Migration Token を表示し直すのに使用。無くても動きます）
#           reprint.phar（無ければ初回実行時に WordPress.org から自動ダウンロード）
#
set -Eeuo pipefail

WP_CLI="${WP_CLI:-wp}"
PHP_BIN="${PHP_BIN:-php}"
# 常に最新の安定版を返す配布 URL（https://github.com/WordPress/reprint#try-it-with-the-demo-site）
REPRINT_PHAR_URL="${REPRINT_PHAR_URL:-https://plugins.svn.wordpress.org/reprint/downloads/reprint.phar}"

usage() {
  cat <<'EOF'
Usage:
  instawp-reprint.sh <remote_url> [options] [-- <reprint pull の追加オプション>]

  InstaWP のサイト（SSH）で、wp-config.php から DB 接続情報を、DB からサイト URL (siteurl) を
  wp-cli で取得し、reprint pull を実行します。
  WordPress のフォルダで実行するか、--path=DIR で指定してください。
  --runtime=none --start-runtime=none は常に付きます（サイトは InstaWP で表示するため）。

Arguments:
  remote_url               コピー元のサイト URL（Basic 認証があれば https://user:pass@example.com）

Options:
  --path=DIR               WordPress のフォルダ（既定: カレントディレクトリ）
  --work-dir=DIR           秘密鍵・state・reprint.phar の既定の置き場所
                           （既定: WordPress のフォルダと同じ階層の private/reprint
                             （InstaWP では /web/<ドメイン>/private/reprint）。
                             private が無ければ ~/reprint/<WordPress のフォルダから作った名前>。
                             どちらにも書き込めなければ WordPress のフォルダ内の .reprint-work-<ランダム>。
                             公開フォルダ内に置くときは、実行時に Web から読めないかを確認します）
  --target-db=NAME         書き込み先 DB（既定: wp-config の DB_NAME）。存在しなければ作成します
  --target-user=USER       既定: wp-config の DB_USER
  --target-pass=PASS       既定: wp-config の DB_PASSWORD
  --target-host=HOST       既定: wp-config の DB_HOST（localhost ならソケット接続）
  --target-port=PORT       既定: DB_HOST に :port があればその値
  --new-site-url=URL       既定: wp option get siteurl
  --private-key-path=PATH  reprint の秘密鍵（既定: <work-dir>/reprint-key-<コピー元のホスト名>.pem）。
                           無ければ reprint keygen で作成し、コピー元に登録する Migration Token と
                           登録先 URL を表示します（対話実行なら登録後に Enter でそのまま pull します）。
                           --secret=TOKEN（接続トークン）を渡した場合は秘密鍵を使いません
  --phar=PATH              reprint.phar（既定: <work-dir>/reprint.phar）
                           無ければ pull の前に REPRINT_PHAR_URL からダウンロードします
  --state-dir=DIR          既定: <work-dir>/state
  --fs-root=DIR            pull したファイルの置き場所（既定: ./.reprint-files）
                           wp-content の symlink 先になるため、Web サーバーの PHP から読める
                           WordPress のフォルダ内に置いてください
  --php=BIN                reprint を実行する PHP（既定: php）。サイトと同じバージョンを推奨
                           （例: --php=php8.2）
  --no-set-table-prefix    pull 後に wp-config の table_prefix をコピー元に合わせない
                           （既定では、接頭辞が違えば wp-config を書き換えます。reprint はコピー元の
                             接頭辞のままテーブルを作り、InstaWP の接頭辞はランダムなため。
                             変更前の wp-config.php は作業フォルダに保存します）
  --keep-debug-settings    pull 後に wp-config のデバッグ設定を変えない
                           （既定では、WP_DEBUG が有効なら WP_DEBUG_DISPLAY を false にして画面に出さず、
                             private フォルダがあれば WP_DEBUG_LOG の出力先を private/debug.log にします。
                             InstaWP の初期設定では Notice が画面に出て、ログも Web から読めるため）
  --no-link-wp-content     pull 後に wp-content を symlink にしない
                           （既定では、pull した wp-content への symlink にします。
                             既存の wp-content は wp-content.bak-<日時> にリネームして残します）
  -n, --dry-run            取得した値と実行するコマンドを表示するだけで終了
  -y, --yes                確認プロンプトを省略
  -h, --help               このヘルプを表示

  相対パスは WordPress のフォルダ基準です。
  上記以外の --xxx と、-- 以降の引数は、そのまま reprint pull に渡します
  （例: --verbose, --exclude-host-plugins）。

Environment:
  WP_CLI                   wp コマンド（既定: wp）
  PHP_BIN                  --php の既定値（既定: php）
  REPRINT_PHAR_URL         reprint.phar のダウンロード元
                           （既定: https://plugins.svn.wordpress.org/reprint/downloads/reprint.phar）

Examples:
  instawp-reprint.sh https://user:pass@example.com
  instawp-reprint.sh https://example.com --php=php8.2 --dry-run
  instawp-reprint.sh https://example.com --path=/path/to/public_html --target-db=reprint_copy
EOF
}

die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "› $*" >&2; }
warn() { echo "⚠ $*" >&2; }

# URL 中の Basic 認証情報を伏せる
mask_url() { printf '%s' "$1" | sed -E 's#^(https?://)[^/@]+@#\1***@#'; }

# 対象の WordPress で wp-cli を実行する
wpc() { "$WP_CLI" --path="$PUBLIC_DIR" "$@"; }

# 確認を取れるか（curl ... | bash で stdin が端末でなくても、端末があれば /dev/tty から読む）
can_prompt() { [[ -t 0 ]] || { : </dev/tty; } 2>/dev/null; }
prompt_read() { if [[ -t 0 ]]; then read -r "$1"; else read -r "$1" </dev/tty; fi; }

# JSON 1 行から "key":"value" の value を取り出す（\/ も戻す）
json_str() { printf '%s' "$2" | sed -n 's/.*"'"$1"'":"\([^"]*\)".*/\1/p' | sed 's#\\/#/#g'; }

# 先頭の ~ をホームディレクトリに展開する
# shellcheck disable=SC2088  # 引数に残った ~ を文字として照合するため
expand_tilde() {
  case "$1" in
    "~")   printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    *)     printf '%s' "$1" ;;
  esac
}

# 絶対パスにする（相対パスは WordPress のフォルダ基準。. と .. は字面のまま解決する）
abs_path() {
  local p part
  local parts=() out=()
  p="$(expand_tilde "$1")"
  [[ "$p" == /* ]] || p="$PUBLIC_DIR/$p"
  IFS=/ read -r -a parts <<< "$p"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..)   if [[ ${#out[@]} -gt 0 ]]; then unset "out[$(( ${#out[@]} - 1 ))]"; fi ;;
      *)    out+=("$part") ;;
    esac
  done
  printf '/%s' ${out[@]+"${out[@]}"}
}

# パス $1 がフォルダ $2 の中（または同じ）か
is_inside() { [[ "$1" == "$2" || "$1" == "$2"/* ]]; }

# パスを作成・書き込みできるか（まだ無ければ、存在する一番近い親フォルダで判定する）
can_create_path() {
  local p="$1"
  while [[ ! -e "$p" ]]; do p="$(dirname "$p")"; done
  [[ -d "$p" && -w "$p" ]]
}

# ランダムな 16 進文字列（$1 バイト分）
random_hex() { "$PHP_BIN" -r "echo bin2hex(random_bytes($1));"; }

# 公開フォルダ内に置く作業フォルダ。
# このスクリプトは公開リポジトリにあるため、固定名だと秘密鍵の URL を推測される。ランダムな名前にし、2 回目以降は既存のものを使う
public_work_dir() {
  local d found=()
  for d in "$PUBLIC_DIR"/.reprint-work-*; do
    if [[ -d "$d" ]]; then found+=("$d"); fi
  done
  if [[ ${#found[@]} -gt 1 ]]; then
    die "WordPress のフォルダ内に作業フォルダが複数あります（${found[*]}）。--work-dir=DIR で使うものを指定してください"
  elif [[ ${#found[@]} -eq 1 ]]; then
    printf '%s' "${found[0]}"
  else
    printf '%s/.reprint-work-%s' "$PUBLIC_DIR" "$(random_hex 16)"
  fi
}

# 作業フォルダに試しにファイルを置き、サイトの URL 経由で取得できるかを確かめる
# 戻り値: 0=Web から取得できない 1=取得できる 2=確認できなかった
probe_web_access() {
  local token file url out code rc=0
  token="probe-$(random_hex 8)"
  file="$WORK_DIR/$token.txt"
  printf '%s' "$token" > "$file" || return 2
  url="${NEW_URL%/}/${WORK_DIR#"$PUBLIC_DIR"/}/$token.txt"
  if command -v curl >/dev/null 2>&1; then
    out="$(curl -sL --max-time 15 -w '\n%{http_code}' "$url" 2>/dev/null)" || rc=$?
    rm -f "$file"
    [[ $rc -eq 0 ]] || return 2
    code="${out##*$'\n'}"
    if [[ "$code" == 200 && "${out%$'\n'*}" == "$token" ]]; then return 1; fi
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then return 0; fi
    return 2
  elif command -v wget >/dev/null 2>&1; then
    out="$(wget -qO- --timeout=15 "$url" 2>/dev/null)" || rc=$?
    rm -f "$file"
    # wget の終了コード 8 は「サーバーがエラー（403 / 404 など）を返した」
    if [[ $rc -eq 0 && "$out" == "$token" ]]; then return 1; fi
    if [[ $rc -eq 0 || $rc -eq 8 ]]; then return 0; fi
    return 2
  fi
  rm -f "$file"
  return 2
}

# WordPress のフォルダのパスから作業フォルダ名を作る（例: web_example.com_public_html）
public_dir_slug() {
  local p="$PUBLIC_DIR"
  if [[ "$p" == "$HOME"/* ]]; then p="${p#"$HOME"/}"; fi
  p="${p#/}"
  printf '%s' "$p" | tr -c 'A-Za-z0-9._-' '_'
}

# URL からホスト名を取り出す（Basic 認証とパスは除き、ポートは残す）
url_host() {
  local h="${1#*://}"
  h="${h%%[/?#]*}"
  h="${h##*@}"
  printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9.-' '_'
}

# url を $2 にダウンロードする（curl が無ければ wget）
fetch() {
  local opts=(-fL --retry 2)
  if command -v curl >/dev/null 2>&1; then
    if [[ -t 2 ]]; then opts+=(--progress-bar); else opts+=(-sS); fi
    curl "${opts[@]}" -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1"
  else
    warn "curl も wget も見つかりません"
    return 1
  fi
}

# reprint.phar をダウンロードして $1 に置く。
# 同じフォルダの一時ファイルに落とし、PHP で --version が通ってから差し替える。
download_phar() {
  local dest="$1" dir tmp ver
  dir="$(dirname "$dest")"
  tmp="$dir/.reprint-download.$$.phar"

  info "reprint.phar が無いため、ダウンロードします: $REPRINT_PHAR_URL"
  mkdir -p "$dir" || die "保存先のフォルダを作成できませんでした: $dir"
  if ! fetch "$REPRINT_PHAR_URL" "$tmp"; then
    rm -f "$tmp"
    die "reprint.phar をダウンロードできませんでした: ${REPRINT_PHAR_URL}（手動で取得して --phar=PATH で指定することもできます）"
  fi
  if ! ver="$("$PHP_BIN" "$tmp" --version 2>/dev/null)" || [[ -z "$ver" ]]; then
    rm -f "$tmp"
    die "ダウンロードした reprint.phar を ${PHP_BIN} で実行できませんでした（php reprint.phar --version が失敗。--php=BIN で別の PHP を指定できます）"
  fi
  mv -f "$tmp" "$dest"
  info "reprint.phar を保存しました: ${dest}（$(printf '%s' "$ver" | head -n 1)）"
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

# Migration Token から Migration Token ID（公開鍵の DER の sha256 の先頭 16 桁。Reprint Server の一覧に出る ID）を求める。
# サーバーに shasum / sha256sum が無いこともあるため PHP で計算する
key_id_from_token() {
  printf '%s' "$1" | "$PHP_BIN" -r 'echo substr(hash("sha256", (string) base64_decode(trim(stream_get_contents(STDIN)), true)), 0, 16);' 2>/dev/null
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
  out="$("$PHP_BIN" "$PHAR_PATH" preflight "$(reprint_api_url "$REMOTE")" --state-dir="$dir" --fs-root="$FS_ROOT" \
         --private-key-path="$KEY_FILE" ${opts[@]+"${opts[@]}"} 2>/dev/null)" || rc=$?
  rm -rf "$dir"
  [[ $rc -eq 0 ]] && return 0
  code="$(printf '%s\n' "$out" | grep -o '"error_code":"[A-Z_]*"' | tail -n 1 | sed 's/.*:"//; s/"$//')" || code=""
  case "$code" in
    AUTH_NOT_CONFIGURED|AUTH_UNKNOWN_KEY) return 2 ;;
  esac
  return 1
}

# Migration Token と登録手順を表示する
show_enroll_guide() {
  local token="$1" key_id="${2:-}"
  cat >&2 <<EOF

  ── コピー元に Migration Token を登録してください ─────────────────
  1. $(reprint_admin_url "$REMOTE") を開く（ツール → Reprint Server）
  2. 下の Migration Token を貼り付けて「Authorize client」を押す
  秘密鍵: ${KEY_FILE}${key_id:+  (Migration Token ID: ${key_id})}

${token}

EOF
}

# 登録を待つ。対話実行なら Enter で続行して 0 を返し、それ以外は再実行を案内して 1 を返す
wait_for_enroll() {
  if [[ $ASSUME_YES -ne 1 ]] && can_prompt; then
    printf '登録したら Enter を押してください（中止: Ctrl+C）' >&2
    prompt_read _ || return 1
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
  out="$("$PHP_BIN" "$PHAR_PATH" keygen "$REMOTE" --state-dir="$STATE_DIR" --out="$KEY_FILE" --progress=jsonl 2>/dev/null \
         | grep '"reprint_report"' | tail -n 1)" || true
  token="$(json_str public_key "$out")"
  key_id="$(json_str key_id "$out")"
  if [[ -z "$token" || ! -f "$KEY_FILE" ]]; then
    err="$(json_str error "$out")"
    die "秘密鍵を作成できませんでした${err:+: ${err}}"
  fi
  # 共用サーバーで他のユーザーから読まれないようにする
  chmod 600 "$KEY_FILE" 2>/dev/null || warn "秘密鍵のパーミッションを 600 にできませんでした: $KEY_FILE"
  info "秘密鍵を作成しました"
  show_enroll_guide "$token" "$key_id"
}

# wp-config.php を書き換える前に、1 回だけ作業フォルダへ保存する
# （DB のパスワードがあるため公開フォルダには置かない）
CONFIG_BACKUP=""
backup_wp_config() {
  local f
  [[ -z "$CONFIG_BACKUP" ]] || return 0
  f="$WORK_DIR/wp-config.php.bak-$(date +%Y%m%d-%H%M%S)"
  if ! { cp -p "$CONFIG_FILE" "$f" && chmod 600 "$f"; }; then
    warn "wp-config.php を保存できなかったため、変更しません: $f"
    return 1
  fi
  CONFIG_BACKUP="$f"
  info "変更前の wp-config.php を保存しました: $CONFIG_BACKUP"
}

# wp-config のデバッグ設定を、コピーしたサイトの表示に合わせる。
# InstaWP の初期設定は WP_DEBUG・WP_DEBUG_LOG が有効で WP_DEBUG_DISPLAY が未定義（＝画面に出す）のため、
# コピー元プラグインの Notice が画面や REST API の応答に混ざり、ログも公開フォルダの wp-content/debug.log に出る
adjust_debug_settings() {
  local display log old_log moved
  [[ "$CFG_WP_DEBUG" == 1 ]] || return 0

  display="$(config_value WP_DEBUG_DISPLAY)" || display=1
  if [[ "$display" == 1 ]]; then
    if backup_wp_config && wpc config set WP_DEBUG_DISPLAY false --raw >/dev/null; then
      info "WP_DEBUG_DISPLAY を false にしました（エラーは画面に出さず、ログにだけ出します）"
    else
      warn "WP_DEBUG_DISPLAY を変更できませんでした"
    fi
  fi

  # PHP-FPM と SSH（chroot）でフォルダの見え方が違う（/home/<user>/web/… と /web/…）ため、パスは __DIR__ 基準で書く
  [[ "$(dirname "$CONFIG_FILE")" == "$PUBLIC_DIR" && -d "$PRIVATE_DIR" && -w "$PRIVATE_DIR" ]] || return 0
  log="$(config_value WP_DEBUG_LOG)" || log=""
  [[ "$log" == 1 ]] || return 0
  if backup_wp_config \
     && wpc config set WP_DEBUG_LOG "dirname( __DIR__ ) . '/$(basename "$PRIVATE_DIR")/debug.log'" --raw >/dev/null; then
    info "WP_DEBUG_LOG の出力先を $PRIVATE_DIR/debug.log にしました（Web から読めない場所）"
    old_log="$PUBLIC_DIR/wp-content/debug.log"
    if [[ -f "$old_log" ]]; then
      moved="$PRIVATE_DIR/debug.log.moved-$(date +%Y%m%d-%H%M%S)"
      mv "$old_log" "$moved" && info "Web から読める wp-content/debug.log を移動しました: $moved"
    fi
  else
    warn "WP_DEBUG_LOG を変更できませんでした"
  fi
}

# fs-root 内の wp-content を指す symlink のパス（fs-root が相対なら WordPress のフォルダからの相対パス）
link_target_for() {
  local root="${FS_ROOT%/}"
  root="${root#./}"
  printf '%s%s' "$root" "$1"
}

# wp-content を、pull した wp-content への symlink にする。
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
[[ $# -ge 1 ]] || { usage >&2; exit 1; }

REMOTE="$1"; shift
[[ "$REMOTE" =~ ^https?:// ]] || die "remote_url は http(s):// で始めてください: $(mask_url "$REMOTE")"
# reprint は URL の文字列から state 内の記録の場所（remotes/<URL の md5>）を決めるため、
# 末尾の / の有無だけで別のサイト扱いになり、前回の続きから同期できなくなる。表記をそろえるため取り除く
while [[ "$REMOTE" == */ ]]; do REMOTE="${REMOTE%/}"; done

WP_PATH="."; OPT_WORK_DIR=""
OPT_DB=""; OPT_USER=""; OPT_PASS=""; OPT_PASS_SET=0; OPT_HOST=""; OPT_PORT=""; OPT_URL=""
OPT_KEY_PATH=""; OPT_PHAR=""; OPT_STATE_DIR=""; FS_ROOT="./.reprint-files"
DRY_RUN=0; ASSUME_YES=0; LINK_WP_CONTENT=1; SET_TABLE_PREFIX=1; KEEP_DEBUG_SETTINGS=0
PASSTHRU=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path=*)             WP_PATH="${1#*=}" ;;
    --work-dir=*)         OPT_WORK_DIR="${1#*=}" ;;
    --target-db=*)        OPT_DB="${1#*=}" ;;
    --target-user=*)      OPT_USER="${1#*=}" ;;
    --target-pass=*)      OPT_PASS="${1#*=}"; OPT_PASS_SET=1 ;;
    --target-host=*)      OPT_HOST="${1#*=}" ;;
    --target-port=*)      OPT_PORT="${1#*=}" ;;
    --new-site-url=*)     OPT_URL="${1#*=}" ;;
    --private-key-path=*) OPT_KEY_PATH="${1#*=}" ;;
    --phar=*)             OPT_PHAR="${1#*=}" ;;
    --state-dir=*)        OPT_STATE_DIR="${1#*=}" ;;
    --fs-root=*)          FS_ROOT="${1#*=}" ;;
    --php=*)              PHP_BIN="${1#*=}" ;;
    --target-engine=*)    [[ "${1#*=}" == "mysql" ]] || die "このスクリプトは --target-engine=mysql 専用です" ;;
    --no-link-wp-content) LINK_WP_CONTENT=0 ;;
    --no-set-table-prefix) SET_TABLE_PREFIX=0 ;;
    --keep-debug-settings) KEEP_DEBUG_SETTINGS=1 ;;
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
[[ $USE_SECRET -eq 1 && -n "$OPT_KEY_PATH" ]] && die "--private-key-path と --secret は同時に指定できません"
[[ $USE_SECRET -eq 1 || -n "$(url_host "$REMOTE")" ]] || die "remote_url からホスト名を取り出せません: $(mask_url "$REMOTE")"

command -v "$WP_CLI" >/dev/null 2>&1 || die "wp (WP-CLI) が見つかりません: ${WP_CLI}（環境変数 WP_CLI で指定できます）"
command -v "$PHP_BIN" >/dev/null 2>&1 || die "PHP が見つかりません: ${PHP_BIN}（--php=BIN で指定できます）"

# ---- WordPress のフォルダ ------------------------------------------------
WP_PATH="$(expand_tilde "$WP_PATH")"
[[ -d "$WP_PATH" ]] || die "フォルダがありません: $WP_PATH"
PUBLIC_DIR="$(cd "$WP_PATH" && pwd -P)"
[[ -f "$PUBLIC_DIR/wp-load.php" ]] \
  || die "WordPress のフォルダではありません（wp-load.php がありません）: ${PUBLIC_DIR}。WordPress のフォルダで実行するか --path=DIR を指定してください"
# reprint に渡す相対パス（--fs-root など）を WordPress のフォルダ基準にする
cd "$PUBLIC_DIR"

# ---- wp-config.php と DB からサイト情報を取得 ----------------------------
info "wp-config.php から DB 情報を、DB からサイト URL (siteurl) を取得しています... ($PUBLIC_DIR)"

WP_ERR="$(mktemp)"
trap 'rm -f "$WP_ERR"' EXIT

CONFIG_FILE="$(wpc config path 2>"$WP_ERR")" \
  || die "wp-config.php を見つけられませんでした: $(head -n 1 "$WP_ERR")"

config_value()   { wpc config get "$1" 2>/dev/null; }
config_missing() { die "wp-config.php から $1 を取得できませんでした（${CONFIG_FILE} を確認してください）"; }

CFG_DB="$(config_value DB_NAME)"          || config_missing DB_NAME
CFG_USER="$(config_value DB_USER)"        || config_missing DB_USER
CFG_HOST="$(config_value DB_HOST)"        || config_missing DB_HOST
CFG_PASS="$(config_value DB_PASSWORD)"    || CFG_PASS=""
CFG_PREFIX="$(config_value table_prefix)" || CFG_PREFIX=""
CFG_WP_DEBUG="$(config_value WP_DEBUG)"   || CFG_WP_DEBUG=""

# siteurl を取得できなかったときは wp のエラー（1 行）を残しておく
CFG_SITEURL="$(wpc option get siteurl --skip-plugins --skip-themes 2>"$WP_ERR")" || CFG_SITEURL=""
SITEURL_ERR="$(grep -m1 'Error' "$WP_ERR" | tr -d '\r' || true)"

# DB に繋がらないと pull もできないので、--new-site-url の有無に関わらずここで止める
if [[ "$SITEURL_ERR" == *データベース接続* || "$SITEURL_ERR" == *"database connection"* ]]; then
  die "DB に接続できません（${SITEURL_ERR}）。${CONFIG_FILE} の DB 設定を確認してください。"
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
elif [[ -n "$CFG_SITEURL" ]]; then
  NEW_URL="$CFG_SITEURL"
else
  die "サイト URL (siteurl) を DB から取得できませんでした${SITEURL_ERR:+（${SITEURL_ERR}）}。--new-site-url=https://<サイト> を指定してください。"
fi

[[ "$TARGET_DB" =~ ^[A-Za-z0-9_]+$ ]] || die "DB 名に使えない文字が含まれています: $TARGET_DB"

# ---- 作業ファイルの置き場所 -----------------------------------------------
# 秘密鍵・state は Web から取得されないよう、書き込めるなら公開フォルダの外に置く。
# 作業フォルダ名は URL ではなくフォルダから作る（pull 途中で DB の siteurl が変わっても同じ state で再開するため）
PRIVATE_DIR="$(dirname "$PUBLIC_DIR")/private"
if [[ -n "$OPT_WORK_DIR" ]]; then
  WORK_DIR="$(abs_path "$OPT_WORK_DIR")"
elif [[ -d "$PRIVATE_DIR" ]] && can_create_path "$PRIVATE_DIR/reprint"; then
  # InstaWP の SSH は HOME が / で書き込めないが、public_html と同じ階層の private には書き込める
  WORK_DIR="$PRIVATE_DIR/reprint"
elif [[ -n "${HOME:-}" ]] && can_create_path "$HOME/reprint/$(public_dir_slug)"; then
  WORK_DIR="$(abs_path "$HOME/reprint/$(public_dir_slug)")"
else
  WORK_DIR="$(public_work_dir)" || exit 1
fi
PHAR_PATH="$(abs_path "${OPT_PHAR:-$WORK_DIR/reprint.phar}")"
STATE_DIR="$(abs_path "${OPT_STATE_DIR:-$WORK_DIR/state}")"
FS_ROOT="$(expand_tilde "$FS_ROOT")"

PHAR_MISSING=0
[[ -f "$PHAR_PATH" ]] || PHAR_MISSING=1

# 秘密鍵（既定はコピー元ごとに <work-dir>/reprint-key-<ホスト名>.pem）。無ければ確認後に作成する
KEY_FILE=""; KEY_MISSING=0
if [[ $USE_SECRET -eq 1 ]]; then
  KEY_LABEL="使わない（--secret の接続トークンで認証）"
else
  KEY_FILE="$(abs_path "${OPT_KEY_PATH:-$WORK_DIR/reprint-key-$(url_host "$REMOTE").pem}")"
  KEY_LABEL="$KEY_FILE"
  if [[ ! -f "$KEY_FILE" ]]; then
    KEY_MISSING=1
    KEY_LABEL+="  ※ 無いため作成します（コピー元で Migration Token の登録が必要）"
  fi
fi

# 作業フォルダの外で公開フォルダ内に置くもの（--private-key-path 等で指定されたとき）は、Web から読めるか確認できないので警告だけ出す
WORK_DIR_IS_PUBLIC=0
is_inside "$WORK_DIR" "$PUBLIC_DIR" && WORK_DIR_IS_PUBLIC=1
PUBLIC_EXPOSED=""
if [[ -n "$KEY_FILE" ]] && is_inside "$KEY_FILE" "$PUBLIC_DIR" && ! is_inside "$KEY_FILE" "$WORK_DIR"; then
  PUBLIC_EXPOSED+="秘密鍵"
fi
if is_inside "$STATE_DIR" "$PUBLIC_DIR" && ! is_inside "$STATE_DIR" "$WORK_DIR"; then
  PUBLIC_EXPOSED+="${PUBLIC_EXPOSED:+・}state"
fi

PHP_VERSION_LABEL="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)" || PHP_VERSION_LABEL="不明"

# ---- 実行するコマンド ---------------------------------------------------
CMD=("$PHP_BIN" "$PHAR_PATH" pull "$REMOTE"
  --state-dir="$STATE_DIR" --fs-root="$FS_ROOT"
  --target-engine=mysql --target-host="$TARGET_HOST"
  --target-db="$TARGET_DB" --target-user="$TARGET_USER" --target-pass="$TARGET_PASS"
  --new-site-url="$NEW_URL"
  --runtime=none --start-runtime=none)
[[ -n "$TARGET_PORT" ]] && CMD+=(--target-port="$TARGET_PORT")
[[ -n "$KEY_FILE"    ]] && CMD+=(--private-key-path="$KEY_FILE")
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
  printf '  cd %q && %s\n' "$PUBLIC_DIR" "${out% }"
}

cat >&2 <<EOF

  WordPress    : $PUBLIC_DIR
  コピー元     : $(mask_url "$REMOTE")
  書き込み先 DB: $TARGET_DB  (user=$TARGET_USER host=$TARGET_HOST${TARGET_PORT:+ port=$TARGET_PORT})$( [[ "$TARGET_DB" != "$CFG_DB" ]] && printf '  ※ wp-config の DB_NAME は %s' "$CFG_DB" )
  新しい URL   : $NEW_URL
  作業フォルダ : $WORK_DIR$( [[ $WORK_DIR_IS_PUBLIC -eq 1 ]] && printf '  ※ 公開フォルダ内（パーミッション 700。実行時に Web から読めないか確認します）' )
  ファイル     : $FS_ROOT  (state: $STATE_DIR)
  reprint.phar : $PHAR_PATH$( [[ $PHAR_MISSING -eq 1 ]] && printf '  ※ 無いため実行時にダウンロードします' )
  PHP          : $PHP_BIN ($PHP_VERSION_LABEL)
  秘密鍵       : ${KEY_LABEL}
  接頭辞       : wp-config は ${CFG_PREFIX:-不明}。$( [[ $SET_TABLE_PREFIX -eq 1 && "$TARGET_DB" == "$CFG_DB" ]] && echo "コピー元と違えば pull 後に wp-config の table_prefix を合わせる（変更前の wp-config.php は作業フォルダに保存）" || echo "変更しない" )
  デバッグ設定 : $( if [[ $KEEP_DEBUG_SETTINGS -eq 1 || "$CFG_WP_DEBUG" != 1 ]]; then echo "変更しない"; else echo "WP_DEBUG が有効なため、pull 後に画面表示を止める$( [[ -d "$PRIVATE_DIR" ]] && printf '（ログは %s/debug.log に出す）' "$PRIVATE_DIR" )"; fi )
  wp-content   : $( [[ $LINK_WP_CONTENT -eq 1 ]] && echo "pull 後に $FS_ROOT 内の wp-content への symlink にする（既存の実ディレクトリは wp-content.bak-<日時> に退避）" || echo "変更しない" )

EOF
show_cmd >&2
echo >&2
if [[ -n "$PUBLIC_EXPOSED" ]]; then
  warn "${PUBLIC_EXPOSED} が公開フォルダ ($PUBLIC_DIR) 内にあり、Web から取得されるおそれがあります。--work-dir などで外に置いてください。"
fi
# 公開フォルダ内に作った以前の作業フォルダが残っていれば、移すか消すよう案内する（秘密鍵が公開フォルダに残るため）
if [[ $WORK_DIR_IS_PUBLIC -eq 0 ]]; then
  for d in "$PUBLIC_DIR"/.reprint-work-*; do
    [[ -d "$d" ]] || continue
    warn "以前の作業フォルダが公開フォルダ内に残っています: $d"
    if [[ ! -e "$WORK_DIR" ]]; then
      warn "  登録済みの秘密鍵を引き継ぐなら、実行前に移してください: mv $(printf '%q' "$d") $(printf '%q' "$WORK_DIR")"
    else
      warn "  不要なら削除してください: rm -rf $(printf '%q' "$d")"
    fi
  done
fi

if [[ $DRY_RUN -eq 1 ]]; then
  info "--dry-run のため実行しません"
  exit 0
fi

if [[ $ASSUME_YES -ne 1 ]]; then
  can_prompt || die "確認が必要です。非対話で実行する場合は --yes を付けてください。"
  printf 'DB「%s」の同名テーブルはコピー元の内容で上書きされます。続行しますか? [y/N] ' "$TARGET_DB" >&2
  prompt_read ans || ans=""
  [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]] || { info "中止しました"; exit 1; }
fi

# 作業フォルダは自分だけが読めるようにする（秘密鍵と state を置くため）
if [[ ! -d "$WORK_DIR" ]]; then
  if ! { mkdir -p "$WORK_DIR" && chmod 700 "$WORK_DIR"; }; then
    die "作業フォルダを作成できませんでした: ${WORK_DIR}（--work-dir=DIR で書き込める場所を指定してください）"
  fi
fi

# 公開フォルダ内なら、秘密鍵を置く前に Web から読めないかを実際に取得して確かめる
if [[ $WORK_DIR_IS_PUBLIC -eq 1 ]]; then
  chmod 700 "$WORK_DIR" 2>/dev/null || true
  probe=0
  probe_web_access || probe=$?
  case $probe in
    0) info "作業フォルダが Web から読めないことを確認しました" ;;
    1)
      if [[ "$(basename "$WORK_DIR")" != .reprint-work-* ]]; then
        die "作業フォルダ (${WORK_DIR}) のファイルを Web から取得できます。秘密鍵が漏れるため中止します（--work-dir を外すと推測されにくい名前のフォルダを使います）"
      fi
      warn "作業フォルダは Web サーバーから読める設定です。フォルダ名はランダムで推測されにくいものの、URL を知られると秘密鍵を取得されます。作業が終わったら削除してください。"
      ;;
    *) warn "作業フォルダが Web から読めないかを確認できませんでした（${NEW_URL} に接続できない等）" ;;
  esac
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
    key_id="$(key_id_from_token "$token")" || key_id=""
    show_enroll_guide "$token" "$key_id"
    wait_for_enroll || exit 4
  done
fi

# wp-config と別の DB を使う場合は、無ければ作る（既存 DB には何もしない）
if [[ "$TARGET_DB" != "$CFG_DB" ]]; then
  command -v mysql >/dev/null 2>&1 || die "mysql コマンドが無いため DB「${TARGET_DB}」を作成できません（先に DB を作成してください）"
  info "DB「${TARGET_DB}」が無ければ作成します..."
  MYSQL_PWD="$TARGET_PASS" mysql -u"$TARGET_USER" -h "$TARGET_HOST" ${TARGET_PORT:+-P "$TARGET_PORT"} \
    -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
    || die "DB「${TARGET_DB}」を作成できませんでした（ユーザー $TARGET_USER に DB 作成権限があるか確認してください）"
fi

# ---- pull 実行 ----------------------------------------------------------
# 鍵の登録は上で確かめ済み（--private-key-path を渡すと reprint は鍵を自動作成せず、exit 4 も返さない）
status=0
"${CMD[@]}" || status=$?

if [[ $status -ne 0 ]]; then
  # fs-root にファイルがあるのに state に取得の記録が無いと、再実行しても同じところで止まるため、対処を案内する
  if grep -q 'Filesystem root is not empty and no cursor found' "$STATE_DIR/progress.json" 2>/dev/null; then
    warn "reprint pull が失敗しました (exit $status)。"
    warn "${FS_ROOT} に以前 pull したファイルがありますが、state（${STATE_DIR}）にこの URL での取得の記録がありません。"
    warn "  前回の state が残っていれば ${STATE_DIR} に置き、前回と同じ URL で実行すると続きから同期できます。"
    warn "  最初から取り直す場合は、削除してから再実行してください: rm -rf $(printf '%q' "$(abs_path "$FS_ROOT")")"
    exit "$status"
  fi
  warn "reprint pull が失敗しました (exit $status)。同じコマンドを再実行すると続きから再開します。"
  warn "DB に接続できないエラーの場合は --target-user / --target-pass / --target-host を確認してください。"
  exit "$status"
fi

# ---- 後処理 -------------------------------------------------------------
# 出力全体を受け取ってから sourceSite の行を選ぶ（head で途中で閉じると php が SIGPIPE で失敗し、値を取りこぼすため）
META_OUT="$("$PHP_BIN" "$PHAR_PATH" pull-metadata "$REMOTE" --state-dir="$STATE_DIR" 2>/dev/null)" || true
META="$(printf '%s\n' "$META_OUT" | grep -m1 '"sourceSite"' || true)"
REMOTE_PREFIX="$(json_str tablePrefix "$META")"
CONTENT_DIR="$(json_str contentDirectory "$META")"

echo >&2
info "pull が完了しました"

# reprint はコピー元の接頭辞のままテーブルを作るため、wp-config の table_prefix を合わせないとサイトに反映されない
if [[ -z "$REMOTE_PREFIX" ]]; then
  warn "pull-metadata からコピー元のテーブル接頭辞を取得できませんでした。サイトに反映されない場合は、wp-config の table_prefix (${CFG_PREFIX}) と DB のテーブル名を確認してください"
elif [[ "$REMOTE_PREFIX" != "$CFG_PREFIX" ]]; then
  SET_PREFIX_CMD="$(printf 'wp --path=%q config set table_prefix %q --type=variable' "$PUBLIC_DIR" "$REMOTE_PREFIX")"
  if [[ $SET_TABLE_PREFIX -ne 1 || "$TARGET_DB" != "$CFG_DB" ]]; then
    warn "テーブル接頭辞が違います（コピー元: $REMOTE_PREFIX / wp-config: ${CFG_PREFIX}）。サイトに反映するには:"
    printf '    %s\n' "$SET_PREFIX_CMD" >&2
  else
    if backup_wp_config && wpc config set table_prefix "$REMOTE_PREFIX" --type=variable >/dev/null; then
      info "wp-config の table_prefix を ${CFG_PREFIX} から ${REMOTE_PREFIX} に変更しました（元の ${CFG_PREFIX} で始まるテーブルは DB に残っています）"
    else
      warn "wp-config の table_prefix を変更できませんでした。手動で実行してください:"
      printf '    %s\n' "$SET_PREFIX_CMD" >&2
    fi
  fi
fi

[[ $KEEP_DEBUG_SETTINGS -eq 1 ]] || adjust_debug_settings
if [[ "$TARGET_DB" != "$CFG_DB" ]]; then
  warn "wp-config の DB_NAME は「${CFG_DB}」のままです。サイトに反映するには:"
  printf '    wp --path=%q config set DB_NAME %q\n' "$PUBLIC_DIR" "$TARGET_DB" >&2
fi
if [[ $WORK_DIR_IS_PUBLIC -eq 1 ]]; then
  info "作業フォルダ（秘密鍵）は公開フォルダ内にあります。pull し直す予定が無ければ、削除してコピー元の Reprint Server で登録を取り消してください:"
  printf '    rm -rf %q\n' "$WORK_DIR" >&2
fi

# ---- wp-content を pull したディレクトリへの symlink にする ------------------
if [[ -z "$CONTENT_DIR" ]]; then
  warn "pull-metadata から wp-content の場所を取得できなかったため、symlink は作成しません"
elif [[ $LINK_WP_CONTENT -ne 1 ]]; then
  info "wp-content は ${FS_ROOT%/}${CONTENT_DIR} にあります（--no-link-wp-content のため symlink は作成しません）"
else
  link_wp_content "$CONTENT_DIR"
fi
