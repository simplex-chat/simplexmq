#!/bin/bash

# add welcome script to .bashrc
echo "bash /opt/simplex/on_login.sh" >> /root/.bashrc

echo "downloading SMP server release $release_tag"
curl -s https://api.github.com/repos/simplex-chat/simplexmq/releases/tags/{$release_tag} \
| jq -r '.assets[].browser_download_url | select(test("smp-server-ubuntu-20_04-x86-64"))' \
| tr -d \" \
| wget -qi -

echo "preparing for SMP server initiaization"
mv smp-server-ubuntu-20_04-x86-64 /opt/simplex/bin/smp-server
chmod +x /opt/simplex/bin/smp-server

# add /opt/simplex/bin to PATH
cat <<EOT >> /etc/profile.d/simplex.sh
#!/bin/bash

export PATH="$PATH:/opt/simplex/bin"

EOT
source /etc/profile.d/simplex.sh

# prepare SMP server systemd service
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

echo "initializing SMP server"
init_res="/etc/opt/simplex/simplex.conf"
init_res_tmp="/etc/opt/simplex/simplex.tmp"
smp-server init -l > $init_res
tail -n +2 "$init_res" > "$init_res_tmp" && mv "$init_res_tmp" "$init_res"
# turn off websockets support
sed -e '/websockets/s/^/# /g' -i /etc/opt/simplex/smp-server.ini

echo "starting SMP server"
sudo systemctl enable smp-server
sudo systemctl start smp-server
