#!/bin/sh

# Add firewall
echo "y" | ufw enable

# Open ports
ufw allow ssh
ufw allow https
ufw allow 5223
