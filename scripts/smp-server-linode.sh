#!/bin/bash
# <UDF name="enable_store_log" label="Store log - persists SMP queues to append only log and restores them upon server restart." default="on" oneof="on, off" />
# <UDF name="api_token" label="Linode API token - enables StackScript to create tags containing SMP server domain/ip address, transport key hash and server version. Use `domain#hash` or `ip#hash` as SMP server address in the client. Note: minimal permissions token should have are - read/write access to `linodes` (to update linode tags - you need them) and `domains` (to add A record for the chosen 3rd level domain)" default="" />
# <UDF name="fqdn" label="FQDN (Fully qualified domain name) - provide third level domain name (ex: smp.example.com). If provided can be used instead of ip address." default="" />

# log all stdout output to stackscript.log
exec &> >(tee -i /var/log/stackscript.log)
# uncomment next line to enable debugging features
# set -xeo pipefail

cd $HOME

sudo apt-get -y update 
sudo apt-get -y upgrade
sudo apt-get install -y jq

# add firewall
echo "y" | ufw enable
# open ports
ufw allow ssh
ufw allow http
ufw allow 5223

bin_dir="/opt/simplex/bin"
conf_dir="/etc/opt/simplex"
var_dir="/var/opt/simplex"
mkdir -p $bin_dir
mkdir -p $conf_dir
mkdir -p $var_dir

# retrieve latest release info and download smp-server executable
curl -s https://api.github.com/repos/simplex-chat/simplexmq/releases/latest > release.json
jq '.assets[].browser_download_url | select(test("smp-server-ubuntu-20_04-x86-64"))' release.json \
| tr -d \" \
| wget -qi -

mv smp-server-ubuntu-20_04-x86-64 $bin_dir/smp-server
chmod +x $bin_dir/smp-server

cat <<EOT >> /etc/profile.d/simplex.sh
#!/bin/bash

export PATH="$PATH:$bin_dir"

EOT
source /etc/profile.d/simplex.sh

# initialize SMP server
init_opts=()
[[ $ENABLE_STORE_LOG == "on" ]] && init_opts+=(-l)
hash_file="$conf_dir/pubkey_hash"
smp-server init "${init_opts[@]}" | grep "transport key hash:" | cut -f2 -d":" | xargs > $hash_file
# turn off websockets support
sed -e '/websockets/s/^/# /g' -i $conf_dir/smp-server.ini
# create script that will run on login
on_login_script="/opt/simplex/on_login.sh"
cat <<EOT >> $on_login_script
#!/bin/bash
# receives pubkey_hash file location as the first parameter

ip_address=\$(hostname -I | awk '{print\$1}')
hash=\$(cat \$1)

cat <<EOF
********************************************************************************

SMP server address: \$ip_address#\$hash
Check SMP server status with: systemctl status smp-server

To keep this server secure, the UFW firewall is enabled.
All ports are BLOCKED except 22 (SSH), 80 (HTTP), 5223 (SMP server).

********************************************************************************
To stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc
EOF

EOT
chmod +x $on_login_script
echo "bash $on_login_script $hash_file" >> /root/.bashrc

# create A record and update linode's tags
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

     hash=$(cat $hash_file)
     release_version=$(jq '.tag_name' release.json | tr -d \")

     curl -s -H "Content-Type: application/json" \
          -H "Authorization: Bearer $API_TOKEN" \
          -X PUT -d "{\"tags\":[\"$address\",\"#$hash\",\"$release_version\"]}" \
          https://api.linode.com/v4/linode/instances/$LINODE_ID
fi

# create, enable and start SMP server systemd service
cat <<EOT >> /etc/systemd/system/smp-server.service
[Unit]
Description=SMP server systemd service

[Service]
Type=simple
ExecStart=/bin/sh -c "$bin_dir/smp-server start"

[Install]
WantedBy=multi-user.target

EOT
chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server

# cleanup
rm release.json
