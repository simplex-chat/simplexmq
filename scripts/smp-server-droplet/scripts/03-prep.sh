#!/bin/bash

# retrieve latest release info and download smp-server executable
echo "downloading SMP server release $release_tag"
curl -s https://api.github.com/repos/simplex-chat/simplexmq/releases/tags/{$release_tag} \
| jq -r '.assets[].browser_download_url | select(test("smp-server-ubuntu-20_04-x86-64"))' \
| tr -d \" \
| wget -qi -

echo "preparing for SMP server initiaization on first login"
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

# create needed folders
mkdir -p /etc/opt/simplex
mkdir -p /var/opt/simplex

# add line to run on_first_login.sh on first login (this line will be removed by on_first_login.sh)
echo "bash /opt/simplex/on_first_login.sh" >> /root/.bashrc
