#!/usr/bin/env sh
set -eu

# Links to scripts/configs
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

path_conf_info="$path_conf_etc/simplex-info"

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
${GRN}3.${NC} Setup user for server:
    - xmp: ${YLW}${user_smp}${NC}
    - xftp: ${YLW}${user_xftp}${NC}
${GRN}4.${NC} Create systemd services:
    - smp: ${YLW}${path_systemd_smp}${NC}
    - xftp: ${YLW}${path_systemd_xftp}${NC}
${GRN}5.${NC} Install stopscript (systemd), update and uninstallation script:
    - all: ${YLW}${path_bin_update}${NC}, ${YLW}${path_bin_uninstall}${NC}, ${YLW}${path_bin_stopscript}${NC}

Press:
  - ${GRN}1${NC} to install smp server
  - ${GRN}2${NC} to install xftp server
  - ${RED}Ctrl+C${NC} to cancel installation
  
Selection: "

end="Installtion is complete!

Please checkout our server guides:
- smp: ${GRN}https://simplex.chat/docs/server.html${NC}
- xftp: ${GRN}https://simplex.chat/docs/xftp-server.html${NC}

To uninstall with full clean-up, simply run: ${YLW}sudo /usr/local/bin/simplex-servers-uninstall${NC}
"

set_version() {
  ver="${VER:-latest}"

  case "$ver" in 
    latest)
      bin="https://github.com/simplex-chat/simplexmq/releases/latest/download"
      remote_version="$(curl --proto '=https' --tlsv1.2 -sSf -L https://api.github.com/repos/simplex-chat/simplexmq/releases/latest | grep -i "tag_name" | awk -F \" '{print $4}')"
      ;;
    *)
      bin="https://github.com/simplex-chat/simplexmq/releases/download/${ver}"
      remote_version="${ver}"
      ;;
  esac
}

os_test() {
 . /etc/os-release

 case "$VERSION_ID" in
  20.04|22.04) : ;;
  24.04) VERSION_ID='22.04' ;;
  *) printf "${RED}Unsupported Ubuntu version!${NC}\nPlease file Github issue with request to support Ubuntu %s: https://github.com/simplex-chat/simplexmq/issues/new\n" "$VERSION_ID" && exit 1 ;;
 esac

 version="$(printf '%s' "$VERSION_ID" | tr '.' '_')"
 arch="$(uname -p)"

 case "$arch" in
  x86_64) arch="$(printf '%s' "$arch" | tr '_' '-')" ;;
  *)  printf "${RED}Unsupported architecture!${NC}\nPlease file Github issue with request to support %s architecture: https://github.com/simplex-chat/simplexmq/issues/new" "$arch" && exit 1 ;;
 esac

 bin_smp="$bin/smp-server-ubuntu-${version}-${arch}"
 bin_xftp="$bin/xftp-server-ubuntu-${version}-${arch}"
}

setup_bins() {
 eval "bin=\$bin_${1}"
 eval "path=\$path_bin_${1}"

 curl --proto '=https' --tlsv1.2 -sSf -L "$bin" -o "$path" && chmod +x "$path"

 unset bin path
}

setup_users() {
 eval "user=\$user_${1}"

 useradd -M "$user" 2> /dev/null || true

 unset user
}

setup_dirs() {
 # Unquoted varibles, so field splitting can occur
 eval "path_conf=\$path_conf_${1}"
 eval "user=\$user_${1}"

 mkdir -p $path_conf
 mkdir -p $path_conf_info
 printf "local_version_%s='%s'\n" "$1" "$remote_version" >> "$path_conf_info/release"
 chown -R "$user":"$user" $path_conf

 unset path_conf user
}

setup_systemd() {
 eval "scripts_systemd=\$scripts_systemd_${1}"
 eval "path_systemd=\$path_systemd_${1}"

 curl --proto '=https' --tlsv1.2 -sSf -L "$scripts_systemd" -o "$path_systemd"

 unset scripts_systemd path_systemd
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
 
 set_version
 os_test

 mkdir -p $path_conf_info  
}

main() {
 checks
 
 printf "%b\n%b" "${BLU}$logo${NC}" "$welcome"
 read ans

 case "$ans" in
  1) setup='smp' ;;
  2) setup='xftp' ;;
  *) printf 'Installation aborted.\n' && exit 0 ;;
 esac

 printf "Installing binaries..."
 
 for i in $setup; do
  setup_bins "$i"
 done
 
 printf "${GRN} Done!${NC}\n"

 printf "Creating users..."

 for i in $setup; do
  setup_users "$i"
 done

 printf "${GRN} Done!${NC}\n"
 
 printf "Creating directories..."

 for i in $setup; do
  setup_dirs "$i"
 done

 printf "${GRN} Done!${NC}\n"

 printf "Creating systemd services..."

 for i in $setup; do
  setup_systemd "$i"
 done

 printf "${GRN} Done!${NC}\n"

 printf "Installing stopscript, update and uninstallation script..."

 setup_scripts

 printf "${GRN} Done!${NC}\n"

 printf "%b" "$end"
}

main
