#!/bin/sh

# add firewall
echo "y" | ufw enable

# open ports
ufw allow ssh
ufw allow https
ufw allow 5223
