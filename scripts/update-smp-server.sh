#!/bin/bash

# systemd has to be configured to use SIGINT to save and restore undelivered messages after restart.
# Add this to [Service] section:
# KillSignal=SIGINT
curl -L -o /opt/simplex/bin/smp-server-new https://github.com/simplex-chat/simplexmq/releases/latest/download/smp-server-ubuntu-20_04-x86-64
systemctl stop smp-server
cp /var/opt/simplex/smp-server-store.log /var/opt/simplex/smp-server-store.log.bak
mv /opt/simplex/bin/smp-server /opt/simplex/bin/smp-server-old
mv /opt/simplex/bin/smp-server-new /opt/simplex/bin/smp-server
chmod +x /opt/simplex/bin/smp-server
systemctl start smp-server
