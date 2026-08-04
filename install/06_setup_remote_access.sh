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

update_ssh_config_host() {
    local ssh_config="$1"
    local host="$2"
    local port="$3"
    local identity_file="$4"

    touch "$ssh_config"

    awk -v host="$host" '
    BEGIN { skip=0 }
    $1 == "Host" {
        skip = ($2 == host)
    }
    !skip { print }
    ' "$ssh_config" > "${ssh_config}.tmp" &&
    mv "${ssh_config}.tmp" "$ssh_config"

    cat >> "$ssh_config" << EOF

Host $host
    Port $port
    IdentityFile $identity_file

EOF
}


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

    primary_key="/home/$user/.ssh/id_rsa"
    secondary_key="/home/$user/.ssh/id_rsa_secondary"
	ssh_config="/home/$user/.ssh/config"

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
		read -p "Copy SSH key to primary server? (RBINS server : no / other servers : yes): " -rn1
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo -u "$user" ssh-copy-id -i "$primary_key" -p "$primary_sshPort" "$primary_ipServer"
        fi

		primary_ipServer_ip=$(cut -d "@" -f2 <<< $primary_ipServer)
		update_ssh_config_host "$ssh_config" "$primary_ipServer_ip" "$primary_sshPort" "$primary_key"
    fi

    #
    # Copy secondary key
    #
    if $secondary_configured; then

        echo
		read -p "Copy SSH key to secondary server? (RBINS server : no / other servers : yes): " -rn1
        echo

        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo -u "$user" ssh-copy-id -i "$secondary_key" -p "$secondary_sshPort" "$secondary_ipServer"
        fi

		secondary_ipServer_ip=$(cut -d "@" -f2 <<< $secondary_ipServer)
		update_ssh_config_host "$ssh_config" "$secondary_ipServer_ip" "$secondary_sshPort" "$secondary_key"
    fi

    path_to_service=$(echo "$PWD/utils/reverse_ssh.sh" | sed 's/\//\\\//g')
    path_to_h_tools=$(echo "$PWD" | sed 's/\//\\\//g')
    service_file="/etc/systemd/system/hypernets-access.service"

    cp "./install/hypernets-access.service" "$service_file"

    sed -i '/User=$/s/$/'"$user"'/' "$service_file"
    sed -i '/ExecStart=$/s/$/'"$path_to_service"'/' "$service_file"
    sed -i '/WorkingDirectory=$/s/$/'"$path_to_h_tools"'\//' "$service_file"

    chmod 644 "$service_file"

    systemctl daemon-reload
    systemctl enable hypernets-access

    # check if we are running this script over SSH session
    is_ssh_session=false
    pid=$$
    while [[ "$pid" -gt 1 ]]; do
        cmd=$(ps -o comm= -p "$pid" 2>/dev/null)

        if [[ "$cmd" == sshd ]]; then
            is_ssh_session=true
            break
        fi

        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    done

    echo
    echo "Configured reverse SSH tunnel endpoints:"

    if $primary_configured; then
        echo " * Primary   : $primary_ipServer (SSH:$primary_sshPort, Remote:$primary_remoteSSHPort)"
    fi

    if $secondary_configured; then
        echo " * Secondary : $secondary_ipServer (SSH:$secondary_sshPort, Remote:$secondary_remoteSSHPort)"
    fi

    if systemctl is-active --quiet hypernets-access; then
        if $is_ssh_session; then
            echo
            echo "[WARNING] hypernets-access is already running."
            echo "[WARNING] Not restarting because this session is connected via SSH."
            echo
            echo "To apply the new configuration later, run:"
            echo "    sudo systemctl restart hypernets-access"
            echo
        else
            systemctl restart hypernets-access
        fi
    else
        systemctl start hypernets-access
    fi
else
    echo "Exit"
fi
