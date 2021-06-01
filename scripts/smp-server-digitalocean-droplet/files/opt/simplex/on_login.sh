#!/bin/bash
# receives pubkey_hash file location as the first parameter

ip_address=$(hostname -I | awk '{print$1}')
hash=$(cat $1)

cat <<EOF
********************************************************************************

SMP server address: $ip_address#$hash
Check SMP server status with: systemctl status smp-server

To keep this server secure, the UFW firewall is enabled.
All ports are BLOCKED except 22 (SSH), 80 (HTTP), 5223 (SMP server).

********************************************************************************
To stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc
EOF
