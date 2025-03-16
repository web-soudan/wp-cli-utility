#!/bin/bash

htaccess_file=".htaccess"
start_comment="# BEGIN Redirect wp-content media from Production"
end_comment="# END Redirect wp-content media from Production"
action="$1" # 最初の引数を取得

# 削除処理のみを行う場合
if [ "$action" = "--delete" ]; then
  echo "Deleting redirect rules..."

  # 開始コメントと終了コメントの間の行を削除
  start_line=$(grep -n "^$start_comment$" "$htaccess_file" | head -n 1 | cut -d: -f1)
  end_line=$(grep -n "^$end_comment$" "$htaccess_file" | tail -n 1 | cut -d: -f1)

  if [ -n "$start_line" ] && [ -n "$end_line" ] && [ "$start_line" -lt "$end_line" ]; then
    sed "${start_line},${end_line}d" "$htaccess_file" > tempfile && mv tempfile "$htaccess_file"
    echo "Removed lines ${start_line} to ${end_line}"
  else
    echo "Could not find start or end comment, or they are in the wrong order. Skipping removal."
  fi

  exit 0 # 削除処理のみの場合はここで終了
fi

# 通常の処理（削除と追加）
redirect_url="$1" # リダイレクトURLを取得

if [ -z "$redirect_url" ]; then
  echo "Usage: $0 <redirect_url> or $0 --delete"
  exit 1
fi

redirect_rules="
RewriteEngine On
RewriteRule ^(wp-content/uploads/.*)$ $redirect_url/\$1 [R=301,L]
"

# 開始コメントの有無をチェック
if grep -q "^$start_comment$" "$htaccess_file"; then
  echo "$start_comment section found in $htaccess_file. Removing..."

  # 開始コメントと終了コメントの間の行を削除
  start_line=$(grep -n "^$start_comment$" "$htaccess_file" | head -n 1 | cut -d: -f1)
  end_line=$(grep -n "^$end_comment$" "$htaccess_file" | tail -n 1 | cut -d: -f1)

  if [ -n "$start_line" ] && [ -n "$end_line" ] && [ "$start_line" -lt "$end_line" ]; then
    sed "${start_line},${end_line}d" "$htaccess_file" > tempfile && mv tempfile "$htaccess_file"
    echo "Removed lines ${start_line} to ${end_line}"
  else
    echo "Could not find start or end comment, or they are in the wrong order. Skipping removal."
  fi
fi

# 改行、開始コメント、リダイレクトルール、終了コメントを追加
echo "" >> "$htaccess_file"  # 空行を追加
echo "$start_comment" >> "$htaccess_file"
echo "$redirect_rules" >> "$htaccess_file"
echo "$end_comment" >> "$htaccess_file"
echo "Redirect rules added to $htaccess_file"
