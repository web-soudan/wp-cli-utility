#!/bin/bash
#set -euxo pipefail
set -euo pipefail

# Set admin email address
read -p "Please set admin email address (Cancel: n/N): " WP_SET_ADMIN_EMAIL_ADDRESS

# Check cancel
if [[ $WP_SET_ADMIN_EMAIL_ADDRESS == [nN] ]]; then
  echo "Canceld"
  exit 0
fi
wp option update admin_email "$WP_SET_ADMIN_EMAIL_ADDRESS"
wp option update new_admin_email "$WP_SET_ADMIN_EMAIL_ADDRESS"
