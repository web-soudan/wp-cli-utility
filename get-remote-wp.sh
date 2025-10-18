#!/bin/bash
set -euo pipefail

## mod from (https://github.com/web-soudan/wp-cli-utility/blob/main/remote-import_wp.sh)

# Set backup file URL
read -p "Please set backup wpress file URL (Cancel: n/N): " backup_wpress_url

# Check cancel
if [[ $backup_wpress_url == [nN] ]]; then
  echo "Canceld"
  exit 0
fi

echo update all plugin
wp plugin update --all

echo 'Restore from remote wpress file'
wp ai1wm url restore --yes "$backup_wpress_url"

echo 'import Done'
echo '----------------------------------------'

echo 'wp rewrite flush'
wp rewrite flush —hard
wp cache flush

echo '----------------------------------------'

echo 'wp cache flush'
wp cache flush

echo '----------------------------------------'

echo SiteURL : $(wp option get home)
echo Version : $(wp core version)

#echo '----------------------------------------'

#echo 'plugin verify-checksums'
#wp plugin verify-checksums --all

#echo '----------------------------------------'

#echo 'linstall plugin : Query Monitor'
#wp plugin install query-monitor --activate

echo '----------------------------------------'

echo 'find php files(wp-content/uploads)'
find ./wp-content/uploads/ -name "*.php"

echo 'Done'
