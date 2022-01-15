#!/bin/bash

chmod +x /opt/simplex/startup_master.sh

# / Create systemd service for startup master script
cat > /etc/systemd/system/startup-master.service << EOF
[Unit]
Description=Startup master script to download and initialize SMP server from latest release

[Service]
Type=oneshot
ExecStart=/opt/simplex/startup_master.sh

[Install]
WantedBy=multi-user.target

EOF
# Create systemd service for startup master script /

# Start systemd service for startup master script
chmod 644 /etc/systemd/system/startup-master.service
sudo systemctl enable startup-master
sudo systemctl start startup-master
