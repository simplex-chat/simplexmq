#!/bin/bash

chmod +x /opt/simplex/smp_server_startup.sh

# / Create systemd service for startup script
cat > /etc/systemd/system/smp-server-startup.service << EOF
[Unit]
Description=Startup script to download and initialize SMP server from latest release

[Service]
Type=simple
ExecStart=/opt/simplex/smp_server_startup.sh

[Install]
WantedBy=multi-user.target

EOF
# Create systemd service for startup script /

# Start systemd service for startup script
chmod 644 /etc/systemd/system/smp-server-startup.service
sudo systemctl enable smp-server-startup
sudo systemctl start smp-server-startup
