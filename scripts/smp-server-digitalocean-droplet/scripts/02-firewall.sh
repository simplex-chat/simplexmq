#!/bin/sh

# add firewall
echo "y" | ufw enable

# open ports
ufw allow ssh
ufw allow http
ufw allow 5223
