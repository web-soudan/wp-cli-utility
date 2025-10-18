#!/bin/bash
shopt -s expand_aliases


## 日本語化
wp core language install ja
wp core language activate ja


## いろいろなプラグインをインストール
echo "いろいろなプラグインをインストールしますか?  [Y/N]"
read ANSWER1 < /dev/tty

case $ANSWER1 in
    "" | "Y" | "y" | "yes" | "Yes" | "YES" )
    wp plugin install \
    wp-multibyte-patch \
    hello-dolly \
    --activate
    ;;
    "N" | "n" | "no" | "No" | "NO" )
    echo "プラグインのインストールをスキップしました。"
    ;;
    * ) echo "plugin install Done!";;
esac


## テストデータのインポート
echo "テストデータインポートしますか?  [Y/N]"
read ANSWER2 < /dev/tty

case $ANSWER2 in
    "" | "Y" | "y" | "yes" | "Yes" | "YES" )
    wp post delete 1 --force
    wget https://raw.githubusercontent.com/wpaccessibility/a11y-theme-unit-test/refs/heads/master/a11y-theme-unit-test-data.xml
    wp plugin install wordpress-importer --activate
    wp import a11y-theme-unit-test-data.xml --authors=create
    rm a11y-theme-unit-test-data.xml

    ## フロントページの設定
    wp option update show_on_front page

    FRONT_PAGE_ID=$(wp post list --post_type=page --fields=ID,post_title | grep "Front Page$" | awk '{print $1}')
    wp option update page_on_front $FRONT_PAGE_ID

    BLOG_PAGE_ID=$(wp post list --post_type=page --fields=ID,post_title | grep "Blog$" | awk '{print $1}')
    
    
    ;;
    "N" | "n" | "no" | "No" | "NO" )
    echo "テストデータのインポートをスキップしました。"
    ;;
    * ) echo "theme unit test inport Done!";;
esac


## オプション
wp option update timezone_string 'Asia/Tokyo'
wp option update date_format 'Y年n月j日'
wp option update time_format 'H:i'


## プラグインとテーマのアップデート
wp plugin update-all
wp theme update-all

## 翻訳ファイルのアップデート
wp language core update
wp language plugin update --all
wp language theme update --all


## キャッシュのクリア
wp cache flush


## Status
echo "========== WordPress Status =========="
echo "Core Version : $(wp core version)"
echo "Site URL : $(wp option get siteurl)"
echo "Admin Email : $(wp option get admin_email)"
echo "========== Plugin Status =========="
wp plugin status
echo "========== Theme Status =========="
wp theme status

open $(wp option get siteurl)/wp-admin/
