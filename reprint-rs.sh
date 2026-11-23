#!/usr/bin/env bash
# reprint-rs — 日本の共用レンタルサーバーで WordPress の設定を wp-cli で読み取り、reprint pull を実行するラッパー
#
# About:
#   エックスサーバー、さくらのレンタルサーバ、ロリポップ!、ConoHa WING などの共用レンタルサーバーに
#   SSH で入り、WordPress のフォルダで実行します。
#   wp-config.php から DB 情報 (DB_NAME / DB_USER / DB_PASSWORD / DB_HOST) を、
#   DB からサイト URL (siteurl) を wp-cli で取得し、そのサイトに対して
#   reprint (https://developer.wordpress.org/reprint/) の pull を実行します。
#   秘密鍵・state・wp-config.php のバックアップなど Web に公開してはいけないファイルは、
#   ホームディレクトリの ~/reprint/<WordPress のフォルダから作った名前>/ に置きます
#   （reprint.phar は ~/reprint/ に置き、同じアカウントのサイトで共用します）。
#   ホームに書き込めないサーバー（Hostinger の Agency プランのサイト用 SSH ユーザーなど）では、
#   代わりに一時フォルダ（環境変数 TMPDIR、無ければ /tmp）の reprint/ を使います。
#   SSH の php コマンドが古い版（reprint は PHP 7.4 以上が必要）のサーバーでは、新しい PHP を自動で探して使います。
#
# Usage:
#   reprint-rs.sh <remote_url> [options] [-- <reprint の追加オプション>]
#   reprint-rs.sh --help
#
# Requires: wp (WP-CLI), php 7.4 以上, curl または wget
#           openssl（鍵の登録が必要になったとき Migration Token を表示し直すのに使用。無くても動きます）
#           rsync（wp-content がマウントされていて symlink に差し替えられないサーバーでのみ使用）
#           reprint.phar（無ければ初回実行時に WordPress.org から自動ダウンロード）
#
set -Eeuo pipefail

WP_CLI="${WP_CLI:-wp}"
# PHP_BIN を環境変数で渡したときは、--php と同じく自動選択しない
PHP_SET=0
[[ -n "${PHP_BIN:-}" ]] && PHP_SET=1
PHP_BIN="${PHP_BIN:-php}"
# reprint が動く PHP の下限（PHP_VERSION_ID。型付きプロパティを使っているため 7.4）
MIN_PHP_ID=70400
MIN_PHP_LABEL="7.4"
# 常に最新の安定版を返す配布 URL（https://github.com/WordPress/reprint#try-it-with-the-demo-site）
REPRINT_PHAR_URL="${REPRINT_PHAR_URL:-https://plugins.svn.wordpress.org/reprint/downloads/reprint.phar}"

# reprint.phar を読み込んで実行する PHP（php -r 用。引数は <reprint.phar> <reprint の引数...>）。
# 共用サーバーでは他のユーザーが ps でプロセスの引数を見られることがあるため、DB パスワード・Basic 認証付きの URL・
# 接続トークンは引数に載せず、引数には @@RS_REMOTE@@ / @@RS_TARGET_PASS@@ / @@RS_SECRET@@ を置く。
# 値は同名の環境変数で渡し（プロセスの環境変数は本人しか読めない）、ここで引数に戻してから環境変数を消す
# shellcheck disable=SC2016  # PHP のコードなので $ は展開しない
REPRINT_LAUNCHER='
require (function () {
  $map = [];
  foreach (["RS_REMOTE", "RS_TARGET_PASS", "RS_SECRET"] as $k) {
    $v = getenv($k);
    if ($v === false) { continue; }
    $map["@@" . $k . "@@"] = $v;
    putenv($k);
    unset($_ENV[$k], $_SERVER[$k]);
  }
  $args = array_slice($_SERVER["argv"], 1);
  $phar = (string) array_shift($args);
  foreach ($args as $i => $a) { $args[$i] = strtr($a, $map); }
  array_unshift($args, $phar);
  $GLOBALS["argv"] = $_SERVER["argv"] = $args;
  $GLOBALS["argc"] = $_SERVER["argc"] = count($args);
  return $phar;
})();
'

usage() {
  cat <<'EOF'
Usage:
  reprint-rs.sh <remote_url> [options] [-- <reprint pull の追加オプション>]

  共用レンタルサーバー（SSH）で、wp-config.php から DB 接続情報を、DB からサイト URL (siteurl) を
  wp-cli で取得し、reprint pull を実行します。
  WordPress のフォルダで実行するか、--path=DIR で指定してください。
  --runtime=none --start-runtime=none は常に付きます（サイトはレンタルサーバーで表示するため）。

Arguments:
  remote_url               コピー元のサイト URL（Basic 認証があれば https://user:pass@example.com）

Options:
  --path=DIR               WordPress のフォルダ（既定: カレントディレクトリ）
  --work-dir=DIR           秘密鍵・state・wp-config.php のバックアップの置き場所
                           （既定: ~/reprint/<WordPress のフォルダから作った名前>。
                             例: ~/example.com/public_html → ~/reprint/example.com_public_html。
                             ホームに書き込めないサーバーでは、一時フォルダ（TMPDIR、無ければ /tmp）の
                             reprint/<同じ名前>）。
                           Web の公開フォルダの外を指定してください
  --target-db=NAME         書き込み先 DB（既定: wp-config の DB_NAME）。
                           無ければ作成を試みますが、レンタルサーバーでは SQL から DB を作れないことが
                           多いため、コントロールパネルで先に作成してください
  --target-user=USER       既定: wp-config の DB_USER
  --target-pass=PASS       既定: wp-config の DB_PASSWORD
  --target-host=HOST       既定: wp-config の DB_HOST（localhost ならソケット接続）
  --target-port=PORT       既定: DB_HOST に :port があればその値
  --new-site-url=URL       既定: wp option get siteurl
  --private-key-path=PATH  reprint の秘密鍵（既定: <work-dir>/reprint-key-<コピー元のホスト名>.pem）。
                           無ければ reprint keygen で作成し、コピー元に登録する Migration Token と
                           登録先 URL を表示します（対話実行なら登録後に Enter でそのまま pull します）。
                           --secret=TOKEN（接続トークン）を渡した場合は秘密鍵を使いません
  --phar=PATH              reprint.phar（既定: ~/reprint/reprint.phar。--work-dir を指定したときは <work-dir>/reprint.phar。
                           ホームに書き込めないときは一時フォルダの reprint/reprint.phar）
                           無ければ pull の前に REPRINT_PHAR_URL からダウンロードします
  --state-dir=DIR          既定: <work-dir>/state
  --fs-root=DIR            pull したファイルの置き場所（既定: ./.reprint-files）
                           wp-content の symlink 先になるため、Web サーバーから読める
                           WordPress のフォルダ内に置いてください
  --php=BIN                reprint と wp-cli を実行する PHP（既定: php。7.4 未満なら
                           /usr/bin/php8.x・/usr/local/php/8.x/bin/php などから一番新しいものを自動で選びます）
  --no-set-table-prefix    pull 後に wp-config の table_prefix をコピー元に合わせない
                           （既定では、接頭辞が違えば wp-config を書き換えます。reprint はコピー元の
                             接頭辞のままテーブルを作り、簡単インストールの接頭辞はランダムなことが多いため。
                             変更前の wp-config.php は作業フォルダに保存します）
  --keep-debug-settings    pull 後に wp-config のデバッグ設定を変えない
                           （既定では、WP_DEBUG が有効なら WP_DEBUG_DISPLAY を false にして画面に出さず、
                             WP_DEBUG_LOG が有効なら出力先を <work-dir>/debug.log にします。
                             既定の wp-content/debug.log は Web から読めるため）
  --no-link-wp-content     pull 後に wp-content を pull したものに切り替えない
                           （既定では、pull した wp-content への symlink にします。
                             既存の wp-content は wp-content.bak-<日時> にリネームして残します。
                             Web サーバーが symlink をたどらない設定だと画像などが表示されません。
                             wp-content がマウントされていて差し替えられないサーバー（Hostinger の
                             Agency プランなど）では、代わりに rsync で中身を同期し、上書き・削除する
                             ファイルは <work-dir>/wp-content.bak-<日時> に退避します）
  -n, --dry-run            取得した値と実行するコマンドを表示するだけで終了
  -y, --yes                確認プロンプトを省略
  -h, --help               このヘルプを表示

  相対パスは WordPress のフォルダ基準です。
  上記以外の --xxx と、-- 以降の引数は、そのまま reprint pull に渡します
  （例: --verbose, --exclude-host-plugins）。

Environment:
  WP_CLI                   wp コマンド（既定: wp。無ければ ~/bin/wp・~/bin/wp-cli.phar・~/wp-cli.phar を探します）
  PHP_BIN                  --php の既定値
  REPRINT_PHAR_URL         reprint.phar のダウンロード元
                           （既定: https://plugins.svn.wordpress.org/reprint/downloads/reprint.phar）

Examples:
  reprint-rs.sh https://user:pass@example.com
  reprint-rs.sh https://example.com --path=~/example.com/public_html --dry-run
  reprint-rs.sh https://example.com --php=/usr/bin/php8.2 --target-db=reprint_copy
EOF
}

die()  { echo "✗ $*" >&2; exit 1; }
info() { echo "› $*" >&2; }
warn() { echo "⚠ $*" >&2; }

# URL 中の Basic 認証情報を伏せる
mask_url() { printf '%s' "$1" | sed -E 's#^(https?://)[^/@]+@#\1***@#'; }

# 対象の WordPress で wp-cli を実行する（WP_CMD は setup_wp_cli で決める）
WP_CMD=()
wpc() { "${WP_CMD[@]}" --path="$PUBLIC_DIR" "$@"; }

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

# フォルダ $1 から見た $2 の相対パス（どちらも abs_path で正規化した絶対パス）
rel_path() {
  local from="$1" to="$2" up=""
  while [[ "$from" != / && "$to" != "$from" && "$to" != "$from"/* ]]; do
    from="$(dirname "$from")"
    up+="../"
  done
  local rest="${to#"$from"}"
  rest="${rest#/}"
  printf '%s%s' "$up" "$rest"
}

# Web の公開フォルダ内かもしれないパスか。
# WordPress のフォルダ内か、ホームディレクトリの下にレンタルサーバーでよくある公開フォルダ名（public_html・www など）を含む
looks_public() {
  local p="$1" rel part
  local parts=()
  is_inside "$p" "$PUBLIC_DIR" && return 0
  is_inside "$p" "$HOME_P" || return 1
  rel="${p#"$HOME_P"}"
  IFS=/ read -r -a parts <<< "$rel"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      public_html|www|web|htdocs|html|public) return 0 ;;
    esac
  done
  return 1
}

# パスを作成・書き込みできるか（まだ無ければ、存在する一番近い親フォルダで判定する）。
# AppArmor で書き込み先を絞っているサーバー（Hostinger の Agency プランなど）では、パーミッション上は
# 書き込めても実際には書き込めず、test -w では判定できないため、空のフォルダを作って消して確かめる
can_create_path() {
  local p="$1" probe
  while [[ ! -e "$p" ]]; do p="$(dirname "$p")"; done
  [[ -d "$p" ]] || return 1
  probe="$p/.reprint-rs-probe.$$"
  mkdir "$probe" 2>/dev/null || return 1
  rmdir "$probe" 2>/dev/null || true
}

# ホームに書き込めないときに作業ファイルを置く一時フォルダ内の場所（TMPDIR、無ければ /tmp の reprint）。使えなければ失敗。
# /tmp は他のユーザーと共用のことがあるため、既にあれば自分が所有する（symlink でない）フォルダのときだけ使う
tmp_reprint_home() {
  local base="${TMPDIR:-/tmp}"
  base="${base%/}/reprint"
  if [[ -e "$base" || -L "$base" ]]; then
    [[ -d "$base" && ! -L "$base" && -O "$base" ]] || return 1
  fi
  can_create_path "$base/$(public_dir_slug)" || return 1
  printf '%s' "$base"
}

# フォルダ $1 がマウントポイントか（mountpoint コマンドが無ければ /proc/self/mountinfo の 5 列目で調べる）
is_mount_point() {
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$1"
    return
  fi
  [[ -r /proc/self/mountinfo ]] || return 1
  cut -d' ' -f5 /proc/self/mountinfo | grep -qxF "$1"
}

# WordPress のフォルダのパスから作業フォルダ名を作る（例: ~/example.com/public_html → example.com_public_html）
public_dir_slug() {
  local p="$PUBLIC_DIR"
  if [[ "$p" == "$HOME_P"/* ]]; then p="${p#"$HOME_P"/}"; fi
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

# PHP のバージョン（PHP_VERSION_ID）。実行できなければ失敗
php_version_id() {
  local v
  v="$("$1" -r 'echo PHP_VERSION_ID;' 2>/dev/null)" || return 1
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$v"
}

# reprint を動かせる PHP（MIN_PHP_ID 以上）を、レンタルサーバーでよくある場所から探して一番新しいものを返す
find_php() {
  local c v best="" best_v=0
  local cands=()
  for c in php8.5 php8.4 php8.3 php8.2 php8.1 php8.0 php7.4 php85 php84 php83 php82 php81 php80 php74; do
    if command -v "$c" >/dev/null 2>&1; then cands+=("$(command -v "$c")"); fi
  done
  # 一致しないパターンは文字のまま残るが、-x で除外される
  for c in /usr/bin/php[78]* /usr/local/bin/php[78]* /usr/local/php/[78].*/bin/php /opt/php-[78].*/bin/php \
           /opt/php[78]*/bin/php /opt/alt/php[78]*/usr/bin/php /opt/cpanel/ea-php[78]*/root/usr/bin/php \
           /opt/remi/php[78]*/root/usr/bin/php; do
    if [[ -f "$c" && -x "$c" ]]; then cands+=("$c"); fi
  done
  for c in ${cands[@]+"${cands[@]}"}; do
    v="$(php_version_id "$c")" || continue
    if [[ $v -gt $best_v ]]; then best="$c"; best_v=$v; fi
  done
  [[ $best_v -ge $MIN_PHP_ID ]] || return 1
  printf '%s' "$best"
}

# wp-cli を reprint と同じ PHP で動かすように WP_CMD を決める。
# レンタルサーバーでは php コマンドが古い版のことがあり、wp（phar）が古い php で起動すると WordPress を読み込めないため
setup_wp_cli() {
  local path="" first c
  if [[ "$WP_CLI" == */* || "$WP_CLI" == "~"* ]]; then
    path="$(expand_tilde "$WP_CLI")"
    [[ -f "$path" ]] || path=""
  elif command -v "$WP_CLI" >/dev/null 2>&1; then
    path="$(command -v "$WP_CLI")"
  else
    for c in "$HOME/bin/wp" "$HOME/bin/wp-cli.phar" "$HOME/wp-cli.phar"; do
      if [[ -f "$c" ]]; then path="$c"; break; fi
    done
  fi
  [[ -n "$path" ]] || return 1
  first="$(head -n 1 "$path" 2>/dev/null | cut -c1-100 | tr -d '\000')" || first=""
  if [[ "$first" == '#!'*php* || "$first" == '<?php'* ]]; then
    # phar（PHP スクリプト）は PHP を指定して起動する
    WP_CMD=("$PHP_BIN" "$path")
  else
    # シェルスクリプトのランチャーは WP_CLI_PHP で PHP を選べる
    [[ -x "$path" ]] || return 1
    export WP_CLI_PHP="$PHP_BIN"
    WP_CMD=("$path")
  fi
}

# reprint.phar を実行する（引数の @@RS_*@@ は、REPRINT_LAUNCHER が環境変数の値に戻す）
reprint_run() {
  RS_REMOTE="$REMOTE" RS_TARGET_PASS="${TARGET_PASS:-}" RS_SECRET="$SECRET_VALUE" \
    "$PHP_BIN" -r "$REPRINT_LAUNCHER" -- "$PHAR_PATH" "$@"
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
  out="$(reprint_run preflight "$(reprint_api_url "$REMOTE_ARG")" --state-dir="$dir" --fs-root="$FS_ROOT" \
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
  out="$(reprint_run keygen "$REMOTE_ARG" --state-dir="$STATE_DIR" --out="$KEY_FILE" --progress=jsonl 2>/dev/null \
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
# WP_DEBUG が有効だと、コピー元プラグインの Notice が画面や REST API の応答に混ざり、
# WP_DEBUG_LOG が true だとログが Web から読める wp-content/debug.log に出るため
adjust_debug_settings() {
  local display log rel old_log moved
  [[ "$CFG_WP_DEBUG" == 1 ]] || return 0

  display="$(config_value WP_DEBUG_DISPLAY)" || display=1
  if [[ "$display" == 1 ]]; then
    if backup_wp_config && wpc config set WP_DEBUG_DISPLAY false --raw >/dev/null; then
      info "WP_DEBUG_DISPLAY を false にしました（エラーは画面に出さず、ログにだけ出します）"
    else
      warn "WP_DEBUG_DISPLAY を変更できませんでした"
    fi
  fi

  log="$(config_value WP_DEBUG_LOG)" || log=""
  [[ "$log" == 1 ]] || return 0
  # SSH と Web の PHP でフォルダの見え方が違うサーバーもあるため、パスは wp-config.php の __DIR__ 基準で書く
  rel="$(rel_path "$(dirname "$CONFIG_FILE")" "$WORK_DIR/debug.log")"
  rel="${rel//\'/\\\'}"
  if backup_wp_config && wpc config set WP_DEBUG_LOG "__DIR__ . '/${rel}'" --raw >/dev/null; then
    info "WP_DEBUG_LOG の出力先を $WORK_DIR/debug.log にしました（Web から読めない場所。Web の PHP が書き込めない設定のサーバーでは、ログはサーバーのエラーログに出ます）"
    old_log="$PUBLIC_DIR/wp-content/debug.log"
    if [[ -f "$old_log" ]]; then
      moved="$WORK_DIR/debug.log.moved-$(date +%Y%m%d-%H%M%S)"
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

# wp-content の中身を、pull した wp-content に rsync で同期する。
# wp-content がマウントされていて、リネームも symlink への差し替えもできないサーバー（Hostinger の Agency プランなど）向け。
# 上書き・削除する元のファイルは、Web から読めない作業フォルダの wp-content.bak-<日時> に退避する
sync_wp_content() {
  local pulled_dir content_dir backup entry name
  local excludes=()
  pulled_dir="$(link_target_for "$1")"
  [[ "$pulled_dir" == /* ]] || pulled_dir="$PUBLIC_DIR/$pulled_dir"
  [[ -d "$pulled_dir" ]] || { warn "pull した wp-content が見つかりません: $pulled_dir"; return 1; }
  content_dir="$PUBLIC_DIR/wp-content"
  backup="$WORK_DIR/wp-content.bak-$(date +%Y%m%d-%H%M%S)"

  # wp-content 直下の symlink はサーバーが管理しているもの（Hostinger の mu-plugins など）なので、同期せずに残す
  for entry in "$content_dir"/* "$content_dir"/.[!.]* "$content_dir"/..?*; do
    [[ -L "$entry" ]] || continue
    name="$(basename "$entry")"
    excludes+=("--exclude=/$name")
    if [[ -e "$pulled_dir/$name" || -L "$pulled_dir/$name" ]]; then
      warn "wp-content/$name はこのサーバーが管理する symlink のため、pull した $name は反映しません（${pulled_dir}/${name}）"
    fi
  done

  # 同期（pull した側にないファイルは削除し、上書き・削除する元のファイルは退避する）
  info "pull した wp-content を wp-content に同期しています..."
  if ! rsync -a --delete --backup --backup-dir="$backup" ${excludes[@]+"${excludes[@]}"} "$pulled_dir/" "$content_dir/"; then
    warn "wp-content の同期に失敗しました。同じコマンドを再実行すると同期し直します（pull は続きから再開します）"
    return 1
  fi
  if [[ -d "$backup" ]]; then
    info "wp-content を同期しました（上書き・削除した元のファイルは ${backup} に退避しました）"
  else
    info "wp-content を同期しました"
  fi
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
    --php=*)              PHP_BIN="${1#*=}"; PHP_SET=1 ;;
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

# 秘密を含む引数は目印に置き換え、値は reprint_run が環境変数で渡す（REPRINT_LAUNCHER を参照）
REMOTE_ARG="@@RS_REMOTE@@"
TARGET_PASS_ARG="@@RS_TARGET_PASS@@"
SECRET_VALUE=""
if [[ ${#PASSTHRU[@]} -gt 0 ]]; then
  for i in "${!PASSTHRU[@]}"; do
    case "${PASSTHRU[$i]}" in
      --secret=*)
        SECRET_VALUE="${PASSTHRU[$i]#--secret=}"
        PASSTHRU[i]="--secret=@@RS_SECRET@@"
        ;;
      --secret)
        if [[ -n "${PASSTHRU[i + 1]+x}" ]]; then
          SECRET_VALUE="${PASSTHRU[i + 1]}"
          PASSTHRU[i + 1]="@@RS_SECRET@@"
        fi
        ;;
    esac
  done
fi
[[ $USE_SECRET -eq 1 || -n "$(url_host "$REMOTE")" ]] || die "remote_url からホスト名を取り出せません: $(mask_url "$REMOTE")"

[[ -n "${HOME:-}" && -d "$HOME" ]] || die "ホームディレクトリ (HOME) が見つかりません"
# ホームディレクトリの実際のパス（symlink を解決したもの。WordPress のフォルダと比べるため）
HOME_P="$(cd "$HOME" && pwd -P)"

# ---- PHP を決める ---------------------------------------------------------
# レンタルサーバーでは SSH の php コマンドが古い版のことがある。--php を指定していなければ、古いときは新しい PHP を探す
PHP_ID="$(php_version_id "$PHP_BIN")" || PHP_ID=0
if [[ $PHP_ID -lt $MIN_PHP_ID ]]; then
  if [[ $PHP_SET -eq 1 ]]; then
    die "${PHP_BIN} は PHP ${MIN_PHP_LABEL} 以上ではないか、実行できません（reprint には PHP ${MIN_PHP_LABEL} 以上が必要です）"
  fi
  found="$(find_php)" \
    || die "PHP ${MIN_PHP_LABEL} 以上が見つかりません（php は $( [[ $PHP_ID -gt 0 ]] && echo "PHP_VERSION_ID=$PHP_ID" || echo "実行できません" )）。--php=BIN で指定してください（例: --php=/usr/bin/php8.2）"
  info "php は PHP ${MIN_PHP_LABEL} 未満か実行できないため、${found} を使います（別の PHP を使うときは --php=BIN）"
  PHP_BIN="$found"
fi

setup_wp_cli || die "wp (WP-CLI) が見つかりません: ${WP_CLI}（環境変数 WP_CLI で wp や wp-cli.phar のパスを指定できます）"

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
# 秘密鍵・state・wp-config.php のバックアップは、Web から取得されないようホームディレクトリの ~/reprint 以下に置く。
# 同じアカウントに複数のサイトがあることが多いため、WordPress のフォルダごとに分ける
# （フォルダ名は URL ではなくフォルダから作る。pull 途中で DB の siteurl が変わっても同じ state で再開するため）
REPRINT_HOME="$HOME_P/reprint"
REPRINT_HOME_IS_TMP=0
if [[ -n "$OPT_WORK_DIR" ]]; then
  WORK_DIR="$(abs_path "$OPT_WORK_DIR")"
  PROTECT_DIRS=("$WORK_DIR")
else
  # ホームに書き込めないサーバー（Hostinger の Agency プランのサイト用 SSH ユーザーは、
  # 書き込めるのが公開フォルダと /tmp だけ）では、一時フォルダを使う
  if ! can_create_path "$REPRINT_HOME/$(public_dir_slug)" && tmp_home="$(tmp_reprint_home)"; then
    REPRINT_HOME="$tmp_home"
    REPRINT_HOME_IS_TMP=1
  fi
  WORK_DIR="$REPRINT_HOME/$(public_dir_slug)"
  PROTECT_DIRS=("$REPRINT_HOME" "$WORK_DIR")
fi
if is_inside "$WORK_DIR" "$PUBLIC_DIR"; then
  die "作業フォルダ (${WORK_DIR}) が WordPress のフォルダ内にあり、秘密鍵が Web から取得されるおそれがあります。--work-dir=DIR で公開フォルダの外を指定してください"
fi
can_create_path "$WORK_DIR" || die "作業フォルダを作成できません: ${WORK_DIR}（--work-dir=DIR で書き込める場所を指定してください）"

if [[ -n "$OPT_PHAR" ]]; then
  PHAR_PATH="$(abs_path "$OPT_PHAR")"
elif [[ -n "$OPT_WORK_DIR" ]]; then
  PHAR_PATH="$WORK_DIR/reprint.phar"
else
  PHAR_PATH="$REPRINT_HOME/reprint.phar"
fi
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

# 公開フォルダ内かもしれない場所に秘密鍵・state を置く指定（--work-dir・--private-key-path・--state-dir）は警告する
PUBLIC_EXPOSED=""
if [[ -n "$KEY_FILE" ]] && looks_public "$KEY_FILE"; then PUBLIC_EXPOSED+="秘密鍵（${KEY_FILE}）"; fi
if looks_public "$STATE_DIR"; then PUBLIC_EXPOSED+="${PUBLIC_EXPOSED:+・}state（${STATE_DIR}）"; fi

PHP_VERSION_LABEL="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null)" || PHP_VERSION_LABEL="不明"

# disable_functions で symlink() を無効にしているサーバー（Hostinger など）では、
# コピー元に symlink があると reprint pull が PHP のエラーで止まるため、先に知らせる
PHP_SYMLINK_DISABLED=0
"$PHP_BIN" -r 'exit(function_exists("symlink") ? 0 : 1);' 2>/dev/null || PHP_SYMLINK_DISABLED=1

# pull 後に wp-content をどう切り替えるか（link: symlink に差し替え / sync: 中身を rsync で同期 / none: 変えない）。
# wp-content がマウントされているとリネームできず、symlink に差し替えられないため同期する
WP_CONTENT_MODE="none"
WP_CONTENT_SKIP_REASON="--no-link-wp-content のため"
if [[ $LINK_WP_CONTENT -eq 1 ]]; then
  if ! is_mount_point "$PUBLIC_DIR/wp-content"; then
    WP_CONTENT_MODE="link"
  elif command -v rsync >/dev/null 2>&1; then
    WP_CONTENT_MODE="sync"
  else
    WP_CONTENT_SKIP_REASON="wp-content がマウントされていて symlink に差し替えられず、rsync も無いため"
  fi
fi
case "$WP_CONTENT_MODE" in
  link) WP_CONTENT_PLAN="pull 後に $FS_ROOT 内の wp-content への symlink にする（既存の実ディレクトリは wp-content.bak-<日時> に退避）" ;;
  sync) WP_CONTENT_PLAN="マウントされていて差し替えられないため、pull 後に $FS_ROOT 内の wp-content の中身を rsync で同期する（上書き・削除する元のファイルは ${WORK_DIR}/wp-content.bak-<日時> に退避。直下の symlink はそのまま。pull したファイルと同じだけディスクを使います）" ;;
  *)    WP_CONTENT_PLAN="変更しない（${WP_CONTENT_SKIP_REASON}）" ;;
esac

# ---- 実行するコマンド ---------------------------------------------------
# reprint pull の引数（秘密は目印のまま。reprint_run で実行する）
PULL_ARGS=(pull "$REMOTE_ARG"
  --state-dir="$STATE_DIR" --fs-root="$FS_ROOT"
  --target-engine=mysql --target-host="$TARGET_HOST"
  --target-db="$TARGET_DB" --target-user="$TARGET_USER" --target-pass="$TARGET_PASS_ARG"
  --new-site-url="$NEW_URL"
  --runtime=none --start-runtime=none)
[[ -n "$TARGET_PORT" ]] && PULL_ARGS+=(--target-port="$TARGET_PORT")
[[ -n "$KEY_FILE"    ]] && PULL_ARGS+=(--private-key-path="$KEY_FILE")
PULL_ARGS+=(${PASSTHRU[@]+"${PASSTHRU[@]}"})

# 表示用（パスワード・接続トークンと Basic 認証は伏せる）
show_cmd() {
  local a out=""
  for a in "$PHP_BIN" "$PHAR_PATH" "${PULL_ARGS[@]}"; do
    case "$a" in
      *@@RS_REMOTE@@*)    a="${a//@@RS_REMOTE@@/$(mask_url "$REMOTE")}"; out+="$a " ;;
      *@@RS_*@@*)         out+="${a%%@@RS_*}*** " ;;
      *)                  out+="$(printf '%q' "$a") " ;;
    esac
  done
  printf '  cd %q && %s\n' "$PUBLIC_DIR" "${out% }"
}

CFG_WP_DEBUG_LOG=""
[[ "$CFG_WP_DEBUG" == 1 ]] && { CFG_WP_DEBUG_LOG="$(config_value WP_DEBUG_LOG)" || CFG_WP_DEBUG_LOG=""; }

cat >&2 <<EOF

  WordPress    : $PUBLIC_DIR
  コピー元     : $(mask_url "$REMOTE")
  書き込み先 DB: $TARGET_DB  (user=$TARGET_USER host=$TARGET_HOST${TARGET_PORT:+ port=$TARGET_PORT})$( [[ "$TARGET_DB" != "$CFG_DB" ]] && printf '  ※ wp-config の DB_NAME は %s' "$CFG_DB" )
  新しい URL   : $NEW_URL
  作業フォルダ : ${WORK_DIR}（パーミッション 700）$( [[ $REPRINT_HOME_IS_TMP -eq 1 ]] && printf '  ※ ホームディレクトリに書き込めないため一時フォルダを使います' )
  ファイル     : $FS_ROOT  (state: $STATE_DIR)
  reprint.phar : $PHAR_PATH$( [[ $PHAR_MISSING -eq 1 ]] && printf '  ※ 無いため実行時にダウンロードします' )
  PHP          : $PHP_BIN ($PHP_VERSION_LABEL)
  wp-cli       : ${WP_CMD[*]}
  秘密鍵       : ${KEY_LABEL}
  接頭辞       : wp-config は ${CFG_PREFIX:-不明}。$( [[ $SET_TABLE_PREFIX -eq 1 && "$TARGET_DB" == "$CFG_DB" ]] && echo "コピー元と違えば pull 後に wp-config の table_prefix を合わせる（変更前の wp-config.php は作業フォルダに保存）" || echo "変更しない" )
  デバッグ設定 : $( if [[ $KEEP_DEBUG_SETTINGS -eq 1 || "$CFG_WP_DEBUG" != 1 ]]; then echo "変更しない"; else echo "WP_DEBUG が有効なため、pull 後に画面表示を止める$( [[ "$CFG_WP_DEBUG_LOG" == 1 ]] && printf '（ログは %s/debug.log に出す）' "$WORK_DIR" )"; fi )
  wp-content   : ${WP_CONTENT_PLAN}

EOF
show_cmd >&2
echo >&2
if [[ -n "$PUBLIC_EXPOSED" ]]; then
  warn "${PUBLIC_EXPOSED} が Web の公開フォルダ内かもしれません。Web から取得されるおそれがあるため、--work-dir などで公開フォルダの外に置いてください。"
fi
if [[ $REPRINT_HOME_IS_TMP -eq 1 ]]; then
  warn "作業フォルダが一時フォルダ（${REPRINT_HOME}）にあります。サーバーが一時フォルダを消すと、秘密鍵の登録と pull を最初からやり直すことになります。"
fi
if [[ $PHP_SYMLINK_DISABLED -eq 1 ]]; then
  warn "${PHP_BIN} では symlink() が無効です（disable_functions）。コピー元のファイルに symlink があると、reprint pull が途中で止まります。"
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

# ~/reprint と作業フォルダは自分だけが読めるようにする（秘密鍵と state を置くため）
for d in "${PROTECT_DIRS[@]}"; do
  [[ -d "$d" ]] && continue
  if ! { mkdir -p "$d" && chmod 700 "$d"; }; then
    die "フォルダを作成できませんでした: ${d}（--work-dir=DIR で書き込める場所を指定してください）"
  fi
done

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
  command -v mysql >/dev/null 2>&1 || die "mysql コマンドが無いため DB「${TARGET_DB}」を確認できません（コントロールパネルで DB を作成してから再実行してください）"
  info "DB「${TARGET_DB}」が無ければ作成します..."
  MYSQL_PWD="$TARGET_PASS" mysql -u"$TARGET_USER" -h "$TARGET_HOST" ${TARGET_PORT:+-P "$TARGET_PORT"} \
    -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
    || die "DB「${TARGET_DB}」を作成できませんでした。レンタルサーバーでは SQL から DB を作れないことが多いため、コントロールパネルで DB を作成し、ユーザー ${TARGET_USER} にアクセス権を付けてから再実行してください"
fi

# ---- pull 実行 ----------------------------------------------------------
# 鍵の登録は上で確かめ済み（--private-key-path を渡すと reprint は鍵を自動作成せず、exit 4 も返さない）
status=0
reprint_run "${PULL_ARGS[@]}" || status=$?

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
  warn "（レンタルサーバーの制限で長時間の処理が止められた場合も、再実行で続きから進みます）"
  warn "DB に接続できないエラーの場合は --target-user / --target-pass / --target-host を確認してください。"
  exit "$status"
fi

# ---- 後処理 -------------------------------------------------------------
# 出力全体を受け取ってから sourceSite の行を選ぶ（head で途中で閉じると php が SIGPIPE で失敗し、値を取りこぼすため）
META_OUT="$(reprint_run pull-metadata "$REMOTE_ARG" --state-dir="$STATE_DIR" 2>/dev/null)" || true
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

# ---- wp-content を pull したものに切り替える ---------------------------------
if [[ -z "$CONTENT_DIR" ]]; then
  warn "pull-metadata から wp-content の場所を取得できなかったため、wp-content は切り替えません"
elif [[ "$WP_CONTENT_MODE" == link ]]; then
  link_wp_content "$CONTENT_DIR"
elif [[ "$WP_CONTENT_MODE" == sync ]]; then
  sync_wp_content "$CONTENT_DIR"
else
  info "pull した wp-content は ${FS_ROOT%/}${CONTENT_DIR} にあります（${WP_CONTENT_SKIP_REASON}、wp-content は切り替えません）"
fi
