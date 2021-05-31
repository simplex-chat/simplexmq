#!/bin/bash

ip_address=$(hostname -I | awk '{print$1}')
hash=$(cat /etc/opt/simplex/simplex.conf | grep hash: | cut -f2 -d":" | xargs)

cat <<EOF
********************************************************************************

SMP server address: $ip_address#$hash
Check SMP server status with: systemctl status smp-server

To keep this Droplet secure, the UFW firewall is enabled. $myip
All ports are BLOCKED except 22 (SSH), 80 (HTTP), 5223 (SMP server).

Please read the instructions at
(TODO create instruction at https://marketplace.digitalocean.com/apps/simplex-chat)

********************************************************************************
To stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc
EOF
