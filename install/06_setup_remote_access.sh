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

# Read config file :
source utils/configparser.sh

load_reverse_ssh_server_config primary primary_ipServer primary_sshPort primary_remoteSSHPort primary_configured
load_reverse_ssh_server_config secondary secondary_ipServer secondary_sshPort secondary_remoteSSHPort secondary_configured

two_servers_configured=false
$primary_configured && $secondary_configured && two_servers_configured=true

echo
echo "Read from config_static.ini :"

if $primary_configured; then
    echo "Primary server:"
    echo " * Server credentials : $primary_ipServer"
    echo " * SSH port           : $primary_sshPort"
    echo " * Remote SSH port    : $primary_remoteSSHPort"
    echo
fi

if $secondary_configured; then
    echo "Secondary server:"
    echo " * Server credentials : $secondary_ipServer"
    echo " * SSH port           : $secondary_sshPort"
    echo " * Remote SSH port    : $secondary_remoteSSHPort"
    echo
fi

if ! $primary_configured && ! $secondary_configured; then
    echo "No reverse SSH server is configured."
    exit 1
fi

read -p "   Confirm (y/n) ? " -rn1
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then

    echo
    user="$SUDO_USER"
    path_to_service=$(echo "$PWD/utils/reverse_ssh.sh" | sed 's/\//\\\//g')
    path_to_h_tools=$(echo "$PWD" | sed 's/\//\\\//g')
    service_file="/etc/systemd/system/hypernets-access.service"

    cp "./install/hypernets-access.service" "$service_file"

    sed -i '/User=$/s/$/'"$user"'/' "$service_file"
    sed -i '/ExecStart=$/s/$/'"$path_to_service"'/' "$service_file"
    sed -i '/WorkingDirectory=$/s/$/'"$path_to_h_tools"'\\/' "$service_file"

    chmod 644 "$service_file"

    systemctl daemon-reload
    systemctl enable hypernets-access
    systemctl start hypernets-access

    echo
    echo "Configured reverse SSH tunnel endpoints:"

    if $primary_configured; then
        echo " * Primary   : $primary_ipServer (SSH:$primary_sshPort, Remote:$primary_remoteSSHPort)"
    fi

    if $secondary_configured; then
        echo " * Secondary : $secondary_ipServer (SSH:$secondary_sshPort, Remote:$secondary_remoteSSHPort)"
    fi

else
    echo "Exit"
fi
