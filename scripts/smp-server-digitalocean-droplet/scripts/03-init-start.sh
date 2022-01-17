#!/bin/bash

chmod +x /opt/simplex/server_bootstrap.sh

# / Create systemd service for server bootstrap script
cat > /etc/systemd/system/server-bootstrap.service << EOF
[Unit]
Description=Server bootstrap script that downloads and initializes SMP server from the latest release

[Service]
Type=oneshot
ExecStart=/opt/simplex/server_bootstrap.sh

[Install]
WantedBy=multi-user.target

EOF
# Create systemd service for server bootstrap script /

# Start systemd service for server bootstrap script
chmod 644 /etc/systemd/system/server-bootstrap.service
sudo systemctl enable server-bootstrap
sudo systemctl start server-bootstrap
