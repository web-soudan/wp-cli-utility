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

echo 'find php files(wp-content/uploads)'
find ./wp-content/uploads/ -name "*.php"

echo '----------------------------------------'

echo 'update http -> https'
wp search-replace `wp option get siteurl` `wp option get siteurl | sed s/http:/https:/`

echo '----------------------------------------'

echo 'update admin_email'
wp option update admin_email web@web-soudan.co.jp

echo '----------------------------------------'

echo 'get admin user list to JSON'
echo 'loop processing change admin dashboard color'
users=$(wp user list --role=administrator --format=json)

for user_id in $(echo "$users" | jq '.[] | .ID'); do
  wp user meta update "$user_id" admin_color blue
done

echo '----------------------------------------'

echo 'delete script'
rm ./remote-import_wp.sh

echo '----------------------------------------'

echo 'Done'
