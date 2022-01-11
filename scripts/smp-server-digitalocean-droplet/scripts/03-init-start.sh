#!/bin/bash

bin_dir="/opt/simplex/bin"
binary="$bin_dir/smp-server"
conf_dir="/etc/opt/simplex"

# Download latest release
mkdir -p $bin_dir
curl -L -o $binary https://github.com/simplex-chat/simplexmq/releases/latest/download/smp-server-ubuntu-20_04-x86-64
chmod +x $binary
$binary --version

# Add to PATH
cat <<EOT >> /etc/profile.d/simplex.sh
#!/bin/bash

export PATH="$PATH:$bin_dir"

EOT
source /etc/profile.d/simplex.sh

# Initialize server
smp-server init -l

# Turn off websockets support
sed -e '/websockets/s/^/# /g' -i $conf_dir/smp-server.ini

# Server fingerprint
fingerprint=$(cat $conf_dir/fingerprint)

# On login script
echo "bash /opt/simplex/on_login.sh $fingerprint" >> /root/.bashrc

# Create and start systemd service
cat <<EOT >> /etc/systemd/system/smp-server.service
[Unit]
Description=SMP server systemd service

[Service]
Type=simple
ExecStart=/bin/sh -c "$binary start"

[Install]
WantedBy=multi-user.target

EOT

chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server
