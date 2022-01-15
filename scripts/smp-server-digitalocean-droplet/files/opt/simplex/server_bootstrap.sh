#!/bin/bash

set -eu

if [[ ! -f /opt/simplex/do_initialize_server ]]; then
  touch /opt/simplex/do_initialize_server
elif [[ ! -f /etc/opt/simplex/smp-server.ini ]]; then
  chmod +x /opt/simplex/initialize_server.sh
  /opt/simplex/initialize_server.sh
else
  echo "SMP server already initialized"
fi
