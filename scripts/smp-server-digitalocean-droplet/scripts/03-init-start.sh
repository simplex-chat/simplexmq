#!/bin/bash

# Download latest release
bin_dir="/opt/simplex/bin"
binary="$bin_dir/smp-server"
mkdir -p $bin_dir
curl -L -o $binary https://github.com/simplex-chat/simplexmq/releases/latest/download/smp-server-ubuntu-20_04-x86-64
chmod +x $binary

# / Add to PATH
cat <<EOT >> /etc/profile.d/simplex.sh
#!/bin/bash

export PATH="$PATH:$bin_dir"

EOT
# Add to PATH /

# Source and test PATH
source /etc/profile.d/simplex.sh
smp-server --version

# Initialize server
smp-server init -l

# Server fingerprint
fingerprint=$(cat /etc/opt/simplex/fingerprint)

# On login script
echo "bash /opt/simplex/on_login.sh $fingerprint" >> /root/.bashrc

# / Create systemd service
cat <<EOT >> /etc/systemd/system/smp-server.service
[Unit]
Description=SMP server systemd service

[Service]
Type=simple
ExecStart=/bin/sh -c "$binary start"

[Install]
WantedBy=multi-user.target

EOT
# Create systemd service /

# Start systemd service
chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server
