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
tail -n +2 "simplex.conf" > "simplex.tmp" && mv "simplex.tmp" "simplex.conf"
# turn off websockets support
sed -e '/websockets/s/^/# /g' -i /etc/opt/simplex/smp-server.ini

if [ ! -z "$API_TOKEN" ]; then
     ip_address=$(curl ifconfig.me)
     if [ ! -z "$FQDN" ]; then
         domain_address=$(echo $FQDN | rev | cut -d "." -f 1,2 | rev)
         # create A record if domain is created in linode account
         domain_id=$(curl -H "Authorization: Bearer $API_TOKEN" https://api.linode.com/v4/domains \
         | jq --arg da "$domain_address" '.data[] | select( .domain == $da ) | .id')
         if [[ ! -z $domain_id ]]; then
             curl -s -H "Content-Type: application/json" \
                  -H "Authorization: Bearer $API_TOKEN" \
                  -X POST -d "{\"type\":\"A\",\"name\":\"$FQDN\",\"target\":\"$ip_address\"}" \
                  https://api.linode.com/v4/domains/${domain_id}/records
             address=$FQDN
         else
             address=$ip_address
         fi
     fi

     hash=$(cat simplex.conf | grep hash: | cut -f2 -d":" | xargs)
     release_version=$(jq '.tag_name' release.json | tr -d \")

     # update linode's tags
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
ExecStart=/bin/sh -c "/opt/simplex/bin/smp-server start"

[Install]
WantedBy=multi-user.target

EOT

chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server

# create script that will on login
cat <<EOT >> /opt/simplex/on_login.sh
#!/bin/bash

printf "\n### SMP server address: $address#$hash ###\n"
printf "### to see SMP server status run: systemctl status smp-server ###\n"
printf "### (to stop seeing this message delete line - bash /opt/simplex/on_login.sh - from /root/.bashrc) ###\n\n"

EOT
chmod +x /opt/simplex/on_login.sh
echo "bash /opt/simplex/on_login.sh" >> /root/.bashrc

# cleanup
rm release.json
