#!/bin/bash
#set -euxo pipefail
set -euo pipefail

## All plugin delete,import from remote wpress file

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

echo 'install plugin : All-in-One WP Migration Pro'
wp plugin install https://servmask.com/purchase/***REMOVED***?siteurl=http://demo.local --activate

echo 'initial setup ai1wm'
wget -O temp_wp_options.sql ***REMOVED*** && sed "s/wp_/$(wp config get table_prefix)/g" temp_wp_options.sql | wp db query && rm temp_wp_options.sql

echo 'Restore from remote wpress file'
wp ai1wm url restore --yes "$backup_wpress_url"

echo 'import Done'
echo '----------------------------------------'

echo 'wp rewrite flush'
wp rewrite flush --hard

echo '----------------------------------------'

echo 'wp cache flush'
wp cache flush

echo '----------------------------------------'

echo SiteURL : $(wp option get home)
echo Version : $(wp core version)

#echo '----------------------------------------'

#echo 'plugin verify-checksums'
#wp plugin verify-checksums --all

echo '----------------------------------------'

echo 'linstall plugin : Query Monitor'
wp plugin install query-monitor --activate

echo '----------------------------------------'

echo 'linstall plugin : Theme Check'
wp plugin install theme-check --activate

echo '----------------------------------------'

echo 'find php files(wp-content/uploads)'
find ./wp-content/uploads/ -name "*.php"


echo '----------------------------------------'

echo 'update admin_email'
wp option update admin_email web@web-soudan.co.jp
wp option update new_admin_email web@web-soudan.co.jp

echo '----------------------------------------'

echo 'Done'
