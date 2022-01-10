#!/bin/bash
# <UDF name="enable_store_log" label="Store log - persists SMP queues to append only log and restores them upon server restart." default="on" oneof="on, off" />
# <UDF name="api_token" label="Linode API token - enables StackScript to create tags containing SMP server FQDN / IP address, CA certificate fingerprint and server version. Use `fqdn#fingerprint` or `ip#fingerprint` as SMP server address in the client. Note: minimal permissions token should have are - read/write access to `linodes` (to update linode tags) and `domains` (to add A record for the chosen 3rd level domain)" default="" />
# <UDF name="fqdn" label="FQDN (Fully qualified domain name) - provide third level domain name (ex: smp.example.com). If provided can be used instead of IP address." default="" />

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
init_opts=()
[[ $ENABLE_STORE_LOG == "on" ]] && init_opts+=(-l)
smp-server init "${init_opts[@]}"

# Turn off websockets support
sed -e '/websockets/s/^/# /g' -i $conf_dir/smp-server.ini

# Server fingerprint
fingerprint=$(cat $conf_dir/fingerprint)

# On login script
on_login_script="/opt/simplex/on_login.sh"
cat <<EOT >> $on_login_script
#!/bin/bash
# accepts server's fingerprint as the first parameter
fingerprint=\$1

ip_address=\$(hostname -I | awk '{print\$1}')

cat <<EOF
********************************************************************************

SMP server address: \$ip_address#\$fingerprint
Check SMP server status with: systemctl status smp-server

To keep this server secure, the UFW firewall is enabled.
All ports are BLOCKED except 22 (SSH), 443 (HTTPS), 5223 (SMP server).

********************************************************************************
To stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc
EOF

EOT
chmod +x $on_login_script
echo "bash $on_login_script $fingerprint" >> /root/.bashrc

# Create A record and update Linode's tags
if [ ! -z "$API_TOKEN" ]; then
     ip_address=$(curl ifconfig.me)
     address=$ip_address
     if [ ! -z "$FQDN" ]; then
          domain_address=$(echo $FQDN | rev | cut -d "." -f 1,2 | rev)
          domain_id=$(curl -H "Authorization: Bearer $API_TOKEN" https://api.linode.com/v4/domains \
          | jq --arg da "$domain_address" '.data[] | select( .domain == $da ) | .id')
          if [[ ! -z $domain_id ]]; then
               curl -s -H "Content-Type: application/json" \
                    -H "Authorization: Bearer $API_TOKEN" \
                    -X POST -d "{\"type\":\"A\",\"name\":\"$FQDN\",\"target\":\"$ip_address\"}" \
                    https://api.linode.com/v4/domains/${domain_id}/records
               address=$FQDN
          fi
     fi

     version=$($binary --version | cut -d ' ' -f 3-)

     curl -s -H "Content-Type: application/json" \
          -H "Authorization: Bearer $API_TOKEN" \
          -X PUT -d "{\"tags\":[\"$address\",\"#$fingerprint\",\"$version\"]}" \
          https://api.linode.com/v4/linode/instances/$LINODE_ID
fi

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
