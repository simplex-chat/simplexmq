#!/bin/bash

fingerprint=$1

ip_address=$(hostname -I | awk '{print$1}')

cat <<EOF
********************************************************************************

SMP server address: $ip_address#$fingerprint
Check SMP server status with: systemctl status smp-server

To keep this server secure, the UFW firewall is enabled.
All ports are BLOCKED except 22 (SSH), 443 (HTTPS), 5223 (SMP server).

********************************************************************************
To stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc
EOF
