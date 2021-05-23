#!/bin/bash
# <UDF name="enable_store_log" label="Enable store log - enable saving SMP queues to append only log, and restoring them when the server is started." default="on" oneof="on, off" />
# <UDF name="api_token" label="API Token - enable StackScript to create tags address and hash for SMP server domain/ip address and transport key hash from inside linode. Use "address:port#hash" as SMP server URL. Note: minimal permissions token should have are the following: Account - read/write, Linodes - read/write" default="" />
# <UDF name="domain_address" label="Domain address" default="" />

# log all stdout output to stackscript.log
exec &> >(tee -i /var/log/stackscript.log)
# enable debugging features
set -xeo pipefail

cd $HOME

# download latest release
curl -s https://api.github.com/repos/simplex-chat/simplexmq/releases/latest \
| grep "browser_download_url.*20_04-x86-64*" \
| cut -d : -f 2,3 \
| tr -d \" \
| wget -qi -

# move smp-server executable to /opt/simplex/bin
mv smp-server-ubuntu-20_04-x86-64 smp-server
chmod +x smp-server
mkdir -p /opt/simplex/bin
mv ./smp-server /opt/simplex/bin

# add /opt/simplex/bin to $PATH
echo "export PATH=\"\$PATH:/opt/simplex/bin\"" >> .profile
source ~/.profile

# initialize SMP server
mkdir /etc/opt/simplex
mkdir /var/opt/simplex

# -l enables store log
if [ $ENABLE_STORE_LOG == "on" ]; then
        smp-server init -l > simplex.conf
else
        smp-server init > simplex.conf
fi

# post domain/ip address to linode tag
ip_address=$(curl ifconfig.me)
address=$(if [ -z "$DOMAIN_ADDRESS" ]; then 
        echo $ip_address;
else 
        echo $DOMAIN_ADDRESS;
fi)
curl -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_TOKEN" \
    -X POST -d "{\"label\":\"address:$address\",\"linodes\":[$LINODE_ID]}" \
    https://api.linode.com/v4/tags

# post transport key hash to linode tag
hash=$(cat simplex.conf | grep hash: | cut -f2 -d":" | xargs)
curl -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_TOKEN" \
    -X POST -d "{\"label\":\"hash:$hash\",\"linodes\":[$LINODE_ID]}" \
    https://api.linode.com/v4/tags

# create, enable and start SMP server systemd service
cat <<EOT >> /etc/systemd/system/smp-server.service
[Unit]
Description=SMP server systemd service.

[Service]
Type=simple
ExecStart=/bin/sh -c "/opt/simplex/bin/smp-server start"

[Install]
WantedBy=multi-user.target

EOT

chmod 644 /etc/systemd/system/smp-server.service
sudo systemctl enable smp-server
sudo systemctl start smp-server