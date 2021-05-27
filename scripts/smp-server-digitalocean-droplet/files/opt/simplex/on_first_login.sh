#!/bin/bash

printf "SMP server is nearly ready\n"
printf "Do you want to persist SMP queues to append only log?\n(enables restoring queues info upon server restart)\nprint [y/n]\n"
init_opts=()
while true; do
    read yn
    case $yn in
        [Yy]* ) init_opts+=(-l); break;;
        [Nn]* ) exit;;
        * ) echo "please print one of [y/n]";;
    esac
done

echo "initializing SMP server"
# initialize SMP server
smp-server init "${init_opts[@]}" > simplex.conf

echo "starting SMP server"
sudo systemctl enable smp-server
sudo systemctl start smp-server

# overwrites the root .bashrc with the default .bashrc from the /etc/skel directory
# so the call to run on_first_login.sh script no longer exists
cp -f /etc/skel/.bashrc /root/.bashrc
