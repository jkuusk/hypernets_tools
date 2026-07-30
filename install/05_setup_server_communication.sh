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

load_data_server_config primary primary_ipServer primary_sshPort primary_remoteDir primary_configured
load_data_server_config secondary secondary_ipServer secondary_sshPort secondary_remoteDir secondary_configured

two_servers_configured=false
$primary_configured && $secondary_configured && two_servers_configured=true

echo
echo "Read from config_static.ini :"

if $primary_configured; then
    echo "Primary server:"
    echo " * Server credentials : $primary_ipServer"
    echo " * Remote directory   : $primary_remoteDir"
    echo " * SSH port           : $primary_sshPort"
    echo
fi

if $secondary_configured; then
    echo "Secondary server:"
    echo " * Server credentials : $secondary_ipServer"
    echo " * Remote directory   : $secondary_remoteDir"
    echo " * SSH port           : $secondary_sshPort"
    echo
fi

read -p "   Confirm (y/n) ? " -rn1
echo

if [[ $REPLY =~ ^[Yy]$ ]]; then

    echo

    user="$SUDO_USER"

    primary_key="/home/$user/.ssh/id_rsa"
    secondary_key="/home/$user/.ssh/id_rsa_secondary"

    #
    # Create primary key (backward-compatible)
    #
    if $primary_configured; then
        if [[ ! -f "$primary_key" ]]; then
            sudo -u "$user" ssh-keygen -t rsa -N ""
        fi
    fi

    #
    # Create dedicated secondary key
    #
    if $secondary_configured; then
        if [[ ! -f "$secondary_key" ]]; then
            sudo -u "$user" ssh-keygen -t rsa -f "$secondary_key" -N ""
        fi
    fi

    #
    # Copy primary key
    #
    if $primary_configured; then

        echo
		read -p "Copy SSH key to primary serve ? \n (RBINS server : no / other servers : yes): " -rn1
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo -u "$user" ssh-copy-id -i "$primary_key" -p "$primary_sshPort" "$primary_ipServer"
        fi
    fi

    #
    # Copy secondary key
    #
    if $secondary_configured; then

        echo
		read -p "Copy SSH key to secondary serve ? \n (RBINS server : no / other servers : yes): " -rn1
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo -u "$user" ssh-copy-id -i "$secondary_key" -p "$secondary_sshPort" "$secondary_ipServer"
        fi
    fi

    path_to_service=$(echo "$PWD/utils/hello_server.sh" | sed 's/\//\\\//g')
    path_to_h_tools=$(echo "$PWD" | sed 's/\//\\\//g')

    service_file="/etc/systemd/system/hypernets-hello.service"

    cp "./install/hypernets-hello.service" "$service_file"

    sed -i '/User=$/s/$/'"$user"'/' "$service_file"
    sed -i '/ExecStart=$/s/$/'"$path_to_service"'/' "$service_file"
    sed -i '/WorkingDirectory=$/s/$/'"$path_to_h_tools"'\\/' "$service_file"

    chmod 644 "$service_file"

    systemctl daemon-reload
    systemctl enable hypernets-hello
    systemctl start hypernets-hello
else
    echo "Exit"
fi
