#!/bin/bash

# <UDF name="enable_store_log" label="Store log - persist SMP queues to append only log and restore them upon server restart." default="on" oneof="on, off" />
# <UDF name="api_token" label="Linode API token - enable Linode to create tags with server address, fingerprint and version. Note: minimal permissions token should have are read/write access to `linodes` (to create tags) and `domains` (to add A record for the third level domain if FQDN is provided)." default="" />
# <UDF name="fqdn" label="FQDN (Fully Qualified Domain Name) - provide third level domain name (e.g. smp.example.com). If provided use `smp://fingerprint@FQDN` as server address in the client. If FQDN is not provided use `smp://fingerprint@IP` instead." default="" />

# Log all stdout output to stackscript.log
exec &> >(tee -i /var/log/stackscript.log)

# Uncomment next line to enable debugging features
# set -xeo pipefail

cd $HOME

# https://superuser.com/questions/1638779/automatic-yess-to-linux-update-upgrade
# https://superuser.com/questions/1412054/non-interactive-apt-upgrade
sudo DEBIAN_FRONTEND=noninteractive \
  apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
  update

sudo DEBIAN_FRONTEND=noninteractive \
  apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
  dist-upgrade

# TODO install unattended-upgrades
sudo DEBIAN_FRONTEND=noninteractive \
  apt-get \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -y --allow-downgrades --allow-remove-essential --allow-change-held-packages \
  install jq

# Add firewall
echo "y" | ufw enable

# Open ports
ufw allow ssh
ufw allow https
ufw allow 5223

# Increase file descriptors limit
echo 'fs.file-max = 1000000' >> /etc/sysctl.conf
echo 'fs.inode-max = 1000000' >> /etc/sysctl.conf
echo 'root soft nofile unlimited' >> /etc/security/limits.conf
echo 'root hard nofile unlimited' >> /etc/security/limits.conf

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
init_opts=()

[[ $ENABLE_STORE_LOG == "on" ]] && init_opts+=(-l)

ip_address=$(curl ifconfig.me)
init_opts+=(--ip $ip_address)

[[ -n "$FQDN" ]] && init_opts+=(-n $FQDN)

smp-server init "${init_opts[@]}"

# Server fingerprint
fingerprint=$(cat /etc/opt/simplex/fingerprint)

# Determine server address to specify in welcome script and Linode tag
if [[ -n "$FQDN" ]]; then
  server_address=$FQDN
else
  server_address=$ip_address
fi

# Set up welcome script
on_login_script="/opt/simplex/on_login.sh"

# / Welcome script
cat > $on_login_script << EOF
#!/bin/bash

fingerprint=\$1
server_address=\$2

cat << EOF2
********************************************************************************

SMP server address: smp://\$fingerprint@\$server_address
Check SMP server status with: systemctl status smp-server

To keep this server secure, the UFW firewall is enabled.
All ports are BLOCKED except 22 (SSH), 443 (HTTPS), 5223 (SMP server).

********************************************************************************
To stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc
EOF2

EOF
# Welcome script /

chmod +x $on_login_script
echo "bash $on_login_script $fingerprint $server_address" >> /root/.bashrc

# Create A record and update Linode's tags
if [[ -n "$API_TOKEN" ]]; then
  if [[ -n "$FQDN" ]]; then
    domain_address=$(echo $FQDN | rev | cut -d "." -f 1,2 | rev)
    domain_id=$(curl -H "Authorization: Bearer $API_TOKEN" https://api.linode.com/v4/domains \
    | jq --arg da "$domain_address" '.data[] | select( .domain == $da ) | .id')
    if [[ -n $domain_id ]]; then
      curl \
        -s -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_TOKEN" \
        -X POST -d "{\"type\":\"A\",\"name\":\"$FQDN\",\"target\":\"$ip_address\"}" \
        https://api.linode.com/v4/domains/${domain_id}/records
    fi
  fi

  version=$(smp-server --version | cut -d ' ' -f 3-)

  curl \
    -s -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_TOKEN" \
    -X PUT -d "{\"tags\":[\"$server_address\",\"$fingerprint\",\"$version\"]}" \
    https://api.linode.com/v4/linode/instances/$LINODE_ID
fi

# / Create systemd service
cat > /etc/systemd/system/smp-server.service << EOF
[Unit]
Description=SMP server

[Service]
Type=simple
ExecStart=/bin/sh -c "exec $binary start >> /var/opt/simplex/smp-server.log 2>&1"
KillSignal=SIGINT
TimeoutStopSec=infinity
Restart=always
RestartSec=10
LimitNOFILE=1000000
LimitNOFILESoft=1000000

[Install]
WantedBy=multi-user.target

EOF
# Create systemd service /

# Start systemd service
chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server

# Reboot Linode to apply upgrades
sudo reboot
