#!/bin/bash

printf "SMP server is nearly ready\n"
printf "Do you want to persist SMP queues to append only log?\n(enables restoring queues info upon server restart)\nprint 1/2 for yes/no\n"
init_opts=()
select yn in "yes" "no"; do
    case $yn in
        yes ) init_opts+=(-l); break;;
        no ) exit;;
        *) echo "please print 1 or 2";
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
