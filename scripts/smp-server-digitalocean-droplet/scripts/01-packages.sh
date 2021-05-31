#!/bin/sh

# update apt
apt-get -y update
apt-get -y upgrade

# packages needed for smp-server init-start.sh
apt-get install -y jq
