#!/bin/bash
#set -euxo pipefail
set -euo pipefail

# Set backup file URL
read -p "Please set backup wpress file URL (Cancel: n/N): " backup_wpress_url

# Check cancel
if [[ $backup_wpress_url == [nN] ]]; then
  echo "Canceld"
  exit 0
fi

# deactivate,delete plugins
wp plugin deactivate --all
wp plugin uninstall --all


echo 'linstall plugin : All-in-One WP Migration'
wp plugin install all-in-one-wp-migration --activate

echo 'install plugin : All-in-One WP Migration URL Extension '
wp plugin install https://servmask.com/purchase/***REMOVED*** --activate

echo 'Restore from remote wpress file'
wp ai1wm url restore --yes "$backup_wpress_url"

echo 'Done'
echo '----------------------------------------'

echo SiteURL : $(wp option get home)
echo Version : $(wp core version)

echo '----------------------------------------'

echo 'plugin verify-checksums'
wp plugin verify-checksums --all

echo '----------------------------------------'

echo 'find php files(wp-content/uploads)'
find ./wp-content/uploads/ -name "*.php"

echo '----------------------------------------'
echo 'Done'
