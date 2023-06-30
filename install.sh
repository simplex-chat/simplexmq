#!/usr/bin/env sh
set -eu

# Links to scripts/configs
bin="https://github.com/simplex-chat/simplexmq/releases/latest/download"
bin_smp="$bin/smp-server-ubuntu-20_04-x86-64"
bin_xftp="$bin/xftp-server-ubuntu-20_04-x86-64"

scripts="https://raw.githubusercontent.com/simplex-chat/simplexmq/stable/scripts/main"
scripts_systemd_smp="$scripts/smp-server.service"
scripts_systemd_xftp="$scripts/xftp-server.service"
scripts_update="$scripts/simplex-servers-update"
scripts_uninstall="$scripts/simplex-servers-uninstall"
scripts_stopscript="$scripts/simplex-servers-stopscript"

# Default installation paths
path_bin="/usr/local/bin"
path_bin_smp="$path_bin/smp-server"
path_bin_xftp="$path_bin/xftp-server"
path_bin_update="$path_bin/simplex-servers-update"
path_bin_uninstall="$path_bin/simplex-servers-uninstall"
path_bin_stopscript="$path_bin/simplex-servers-stopscript"

path_conf_etc="/etc/opt"
path_conf_var="/var/opt"
path_conf_smp="$path_conf_etc/simplex $path_conf_var/simplex"
path_conf_xftp="$path_conf_etc/simplex-xftp $path_conf_var/simplex-xftp /srv/xftp"

path_systemd="/etc/systemd/system"
path_systemd_smp="$path_systemd/smp-server.service"
path_systemd_xftp="$path_systemd/xftp-server.service"

# Defaut users
user_smp="smp"
user_xftp="xftp"

GRN='\033[0;32m'
BLU='\033[1;34m'
YLW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

logo='
 ____  _                 _     __  __
/ ___|(_)_ __ ___  _ __ | | ___\ \/ /
\___ \| | '"'"'_ ` _ \| '"'"'_ \| |/ _ \\  / 
 ___) | | | | | | | |_) | |  __//  \ 
|____/|_|_| |_| |_| .__/|_|\___/_/\_\
                  |_|                            
'

welcome="Welcome to SMP/XFTP installation script! Here's what we're going to do:
${GRN}1.${NC} Install latest binaries from GitHub releases:
    - smp: ${YLW}${path_bin_smp}${NC}
    - xftp: ${YLW}${path_bin_xftp}${NC}
${GRN}2.${NC} Create server directories:
    - smp: ${YLW}${path_conf_smp}${NC}
    - xftp: ${YLW}${path_conf_xftp}${NC}
${GRN}3.${NC} Setup user for each server:
    - xmp: ${YLW}${user_smp}${NC}
    - xftp: ${YLW}${user_xftp}${NC}
${GRN}4.${NC} Create systemd services:
    - smp: ${YLW}${path_systemd_smp}${NC}
    - xftp: ${YLW}${path_systemd_xftp}${NC}
${GRN}5.${NC} Install stopscript (systemd), update and uninstallation script:
    - all: ${YLW}${path_bin_update}${NC}, ${YLW}${path_bin_uninstall}${NC}, ${YLW}${path_bin_stopscript}${NC}

Press ${GRN}ENTER${NC} to continue or ${RED}Ctrl+C${NC} to cancel installation"

end="Installtion is complete!

Please checkout our server guides:
- smp: ${GRN}https://simplex.chat/docs/server.html${NC}
- xftp: ${GRN}https://simplex.chat/docs/xftp-server.html${NC}

To uninstall with full clean-up, simply run: ${YLW}sudo /usr/local/bin/simplex-servers-uninstall${NC}
"

setup_bins() {
 curl --proto '=https' --tlsv1.2 -sSf -L "$bin_smp" -o "$path_bin_smp" && chmod +x "$path_bin_smp"
 curl --proto '=https' --tlsv1.2 -sSf -L "$bin_xftp" -o "$path_bin_xftp" && chmod +x "$path_bin_xftp"
}

setup_users() {
 useradd -M "$user_smp" 2> /dev/null || true
 useradd -M "$user_xftp" 2> /dev/null || true
}

setup_dirs() {
 # Unquoted varibles, so field splitting can occur
 mkdir -p $path_conf_smp
 chown "$user_smp":"$user_smp" $path_conf_smp
 mkdir -p $path_conf_xftp
 chown "$user_xftp":"$user_xftp" $path_conf_xftp
}

setup_systemd() {
 curl --proto '=https' --tlsv1.2 -sSf -L "$scripts_systemd_smp" -o "$path_systemd_smp"
 curl --proto '=https' --tlsv1.2 -sSf -L "$scripts_systemd_xftp" -o "$path_systemd_xftp"
}

setup_scripts() {
 curl --proto '=https' --tlsv1.2 -sSf -L "$scripts_update" -o "$path_bin_update" && chmod +x "$path_bin_update"
 curl --proto '=https' --tlsv1.2 -sSf -L "$scripts_uninstall" -o "$path_bin_uninstall" && chmod +x "$path_bin_uninstall"
 curl --proto '=https' --tlsv1.2 -sSf -L "$scripts_stopscript" -o "$path_bin_stopscript" && chmod +x "$path_bin_stopscript"
 }

checks() {
 if [ "$(id -u)" -ne 0 ]; then
  printf "This script is intended to be run with root privileges. Please re-run script using sudo."
  exit 1
 fi
}

main() {
 checks
 
 printf "%b\n%b\n" "${BLU}$logo${NC}" "$welcome"
 read ans

 printf "Installing binaries..."
 setup_bins
 printf "${GRN} Done!${NC}\n"

 printf "Creating users..."
 setup_users
 printf "${GRN} Done!${NC}\n"
 
 printf "Creating directories..."
 setup_dirs
 printf "${GRN} Done!${NC}\n"

 printf "Creating systemd services..."
 setup_systemd
 printf "${GRN} Done!${NC}\n"

 printf "Installing stopscript, update and uninstallation script..."
 setup_scripts
 printf "${GRN} Done!${NC}\n"

 printf "%b" "$end"
}

main
