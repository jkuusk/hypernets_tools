#!/usr/bin/bash

set -o nounset
set -euo pipefail


if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root, use sudo $0 instead" 1>&2
	exit 1
fi

if [[ ${PWD##*/} != "hypernets_tools"* ]]; then
	echo "This script must be run from hypernets_tools folder" 1>&2
	echo "Use : sudo ./install/${0##*/} instead"
	exit 1
fi


source utils/configparser.sh

sshPort=$(parse_config "ssh_port" config_static.ini)
credentials=$(parse_config "credentials" config_static.ini)
remoteSSHPort=$(parse_config "remote_ssh_port" config_static.ini)

if [ -z $remoteSSHPort ]; then
	remoteSSHPort="20213"
fi

if [ -z $sshPort ]; then
	sshPort="22"
fi

echo
echo "Read from config_static.ini : "
echo " * Server credentials : $credentials"
echo " * SSH port           : $sshPort"
echo " * Remote SSH port   : $remoteSSHPort"
read -p "   Confirm (y/n) ?" -rn1
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then 
	echo
	user="$SUDO_USER"
	path_to_service=$(echo "$PWD/utils/reverse_ssh.sh" | sed 's/\//\\\//g')
	path_to_h_tools=$(echo "$PWD" | sed 's/\//\\\//g')
	service_file="/etc/systemd/system/hypernets-access.service"

	cp "./install/hypernets-access.service"  $service_file

	sed -i '/User=$/s/$/'$user'/' $service_file
	sed -i '/ExecStart=$/s/$/'$path_to_service'/' $service_file
	sed -i '/WorkingDirectory=$/s/$/'$path_to_h_tools'\//' $service_file

	chmod 644 $service_file

	systemctl enable hypernets-access
	systemctl start hypernets-access

else
	echo "Exit"
fi
