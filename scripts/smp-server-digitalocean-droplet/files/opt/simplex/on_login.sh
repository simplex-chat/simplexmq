#!/bin/bash

fingerprint=$1
server_address=$2

cat <<EOF
********************************************************************************

SMP server address: smp://$fingerprint@$server_address
Check SMP server status with: systemctl status smp-server

To keep this server secure, the UFW firewall is enabled.
All ports are BLOCKED except 22 (SSH), 443 (HTTPS), 5223 (SMP server).

********************************************************************************
To stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc
EOF
