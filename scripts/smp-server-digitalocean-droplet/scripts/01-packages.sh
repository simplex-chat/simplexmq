#!/bin/sh

# update apt
apt-get -y update
apt-get -y upgrade

# install needed packages
apt-get install -y jq
