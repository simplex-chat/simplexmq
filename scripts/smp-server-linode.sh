#!/bin/bash
# <UDF name="enable_store_log" label="Store log - persists SMP queues to append only log and restores them upon server restart." default="on" oneof="on, off" />
# <UDF name="api_token" label="Linode API token - enables StackScript to create tags containing SMP server domain/ip address, transport key hash and server version. Use "hostname#hash" as SMP server address in the client. Note: minimal permissions token should have are the following: Account - read/write, Linodes - read/write." default="" />
# <UDF name="domain_address" label="If provided can be used instead of ip address." default="" />

# log all stdout output to stackscript.log
exec &> >(tee -i /var/log/stackscript.log)
# enable debugging features
set -xeo pipefail

cd $HOME

sudo apt-get update -y
sudo apt-get install -y jq

# retrieve latest release info and download smp-server executable
curl -s https://api.github.com/repos/simplex-chat/simplexmq/releases/latest > release.json
jq '.assets[].browser_download_url | select(test("smp-server-ubuntu-20_04-x86-64"))' release.json \
| tr -d \" \
| wget -qi -

# move smp-server executable to /opt/simplex/bin
mkdir -p /opt/simplex/bin
mv smp-server-ubuntu-20_04-x86-64 /opt/simplex/bin/smp-server
chmod +x /opt/simplex/bin/smp-server

# add /opt/simplex/bin to $PATH
cat <<EOT >> /etc/profile.d/simplex.sh
#!/bin/bash

export PATH="$PATH:/opt/simplex/bin"

EOT
source /etc/profile.d/simplex.sh

# initialize SMP server
mkdir -p /etc/opt/simplex
mkdir -p /var/opt/simplex
init_opts=()
[[ $ENABLE_STORE_LOG == "on" ]] && init_opts+=(-l)
smp-server init "${init_opts[@]}" > simplex.conf
# turn off websockets support
sed -e '/websockets/s/^/# /g' -i /etc/opt/simplex/smp-server.ini

# prepare tags
ip_address=$(curl ifconfig.me)
address=$([[ -z "$DOMAIN_ADDRESS" ]] && echo $ip_address || echo $DOMAIN_ADDRESS)
hash=$(cat simplex.conf | grep hash: | cut -f2 -d":" | xargs)
release_version=$(jq '.tag_name' release.json | tr -d \")

# update linode's tags
curl -H "Content-Type: application/json" \
     -H "Authorization: Bearer $API_TOKEN" \
     -X PUT -d "{\"tags\":[\"$address\",\"#$hash\",\"$release_version\"]}" \
     https://api.linode.com/v4/linode/instances/$LINODE_ID

# create, enable and start SMP server systemd service
cat <<EOT >> /etc/systemd/system/smp-server.service
[Unit]
Description=SMP server systemd service

[Service]
Type=simple
ExecStart=/bin/sh -c "/opt/simplex/bin/smp-server start"

[Install]
WantedBy=multi-user.target

EOT

chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server
