#!/bin/bash

set -eu

if [[ ! -f /opt/simplex/do_initialize_server ]]; then
  touch /opt/simplex/do_initialize_server
elif [[ -f /etc/opt/simplex/smp-server.ini ]]; then
  echo "SMP server already initialized"
else
  chmod +x /opt/simplex/initialize_smp_server.sh
  /opt/simplex/initialize_smp_server.sh
fi
