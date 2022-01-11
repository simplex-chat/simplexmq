#!/bin/sh

# https://superuser.com/questions/1638779/automatic-yess-to-linux-update-upgrade
# https://superuser.com/questions/1412054/non-interactive-apt-upgrade
sudo DEBIAN_FRONTEND=noninteractive \
  apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
  update

sudo DEBIAN_FRONTEND=noninteractive \
  apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
  dist-upgrade

# TODO install unattended-upgrades; jq is not needed on DigitalOcean
# sudo DEBIAN_FRONTEND=noninteractive \
#   apt-get \
#   -o Dpkg::Options::=--force-confold \
#   -o Dpkg::Options::=--force-confdef \
#   -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
#   install jq
