#!/usr/bin/env bash

echo 'get user list to JSON'
echo 'loop processing change admin dashboard color'
users=$(wp user list --format=json)

for user_id in $(echo "$users" | jq '.[] | .ID'); do
  wp user meta update "$user_id" admin_color sunrise
done
