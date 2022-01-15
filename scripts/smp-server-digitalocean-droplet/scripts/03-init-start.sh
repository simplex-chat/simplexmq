#!/bin/bash

# / Create startup script
cat > /opt/simplex/smp_server_startup.sh << EOF
#!/bin/bash

set -eu

# Download latest release
bin_dir="/opt/simplex/bin"
binary="\$bin_dir/smp-server"
mkdir -p \$bin_dir
curl -L -o \$binary https://github.com/simplex-chat/simplexmq/releases/latest/download/smp-server-ubuntu-20_04-x86-64
chmod +x \$binary

echo \$bin_dir

# / Add to PATH
cat > /etc/profile.d/simplex.sh << EOF2
#!/bin/bash

export PATH="\$PATH:\$bin_dir"

EOF2
# Add to PATH /

# Source and test PATH
source /etc/profile.d/simplex.sh
smp-server --version

# Initialize server
ip_address=\$(hostname -I | awk '{print \$1}')
smp-server init -l --ip \$ip_address

# Server fingerprint
fingerprint=\$(cat /etc/opt/simplex/fingerprint)

# Set up welcome script
echo "bash /opt/simplex/on_login.sh \$fingerprint \$ip_address" >> /root/.bashrc

# / Create systemd service for SMP server
cat > /etc/systemd/system/smp-server.service << EOF2
[Unit]
Description=SMP server systemd service

[Service]
Type=simple
ExecStart=/bin/sh -c "\$binary start"

[Install]
WantedBy=multi-user.target

EOF2
# Create systemd service for SMP server /

# Start systemd service for SMP server
chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server

# Cleanup
sudo systemctl stop smp-server-startup

EOF
# Create startup script /

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

chmod +x /opt/simplex/smp_server_startup.sh

# Start systemd service for startup script
chmod 644 /etc/systemd/system/smp-server-startup.service
sudo systemctl enable smp-server-startup
sudo systemctl start smp-server-startup
