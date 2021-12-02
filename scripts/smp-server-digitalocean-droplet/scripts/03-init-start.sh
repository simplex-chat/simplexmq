#!/bin/bash

bin_dir="/opt/simplex/bin"
conf_dir="/etc/opt/simplex"
var_dir="/var/opt/simplex"
mkdir -p $bin_dir
mkdir -p $conf_dir
mkdir -p $var_dir

echo "downloading the latest SMP server release"
curl -s https://api.github.com/repos/simplex-chat/simplexmq/releases/latest > release.json
jq '.assets[].browser_download_url | select(test("smp-server-ubuntu-20_04-x86-64"))' release.json \
| tr -d \" \
| wget -qi -

release_version=$(jq '.tag_name' release.json | tr -d \")
echo "downloaded SMP server $release_version"
rm release.json

echo "preparing for SMP server initiaization"
mv smp-server-ubuntu-20_04-x86-64 $bin_dir/smp-server
chmod +x $bin_dir/smp-server

cat <<EOT >> /etc/profile.d/simplex.sh
#!/bin/bash

export PATH="$PATH:$bin_dir"

EOT
source /etc/profile.d/simplex.sh

# prepare SMP server systemd service
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

echo "initializing SMP server"
hash_file="$conf_dir/pubkey_hash"
smp-server init -l | grep "transport key hash:" | cut -f2 -d":" | xargs > $hash_file
# turn off websockets support
sed -e '/websockets/s/^/# /g' -i $conf_dir/smp-server.ini
# add welcome script to .bashrc
echo "bash /opt/simplex/on_login.sh $hash_file" >> /root/.bashrc

echo "starting SMP server"
sudo systemctl enable smp-server
sudo systemctl start smp-server
