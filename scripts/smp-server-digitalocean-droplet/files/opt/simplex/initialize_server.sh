#!/bin/bash

# Download latest release
bin_dir="/opt/simplex/bin"
binary="$bin_dir/smp-server"
mkdir -p $bin_dir
curl -L -o $binary https://github.com/simplex-chat/simplexmq/releases/latest/download/smp-server-ubuntu-20_04-x86-64
chmod +x $binary

# / Add to PATH
cat > /etc/profile.d/simplex.sh << EOF
#!/bin/bash

export PATH="$PATH:$bin_dir"

EOF
# Add to PATH /

# Source and test PATH
source /etc/profile.d/simplex.sh
smp-server --version

# Initialize server
ip_address=$(curl ifconfig.me)
smp-server init -l --ip $ip_address

# Server fingerprint
fingerprint=$(cat /etc/opt/simplex/fingerprint)

# Set up welcome script
echo "bash /opt/simplex/on_login.sh $fingerprint $ip_address" >> /root/.bashrc

# / Create systemd service for SMP server
cat > /etc/systemd/system/smp-server.service << EOF
[Unit]
Description=SMP server

[Service]
Type=simple
ExecStart=/bin/sh -c "exec $binary start >> /var/opt/simplex/smp-server.log 2>&1"

[Install]
WantedBy=multi-user.target

EOF
# Create systemd service for SMP server /

# Start systemd service for SMP server
chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server
