#!/usr/bin/bash
# If issues : 
# use autossh with an independant service : 
# see : https://gist.github.com/thomasfr/9707568


# -f : stdin > /dev/null
#
# -N : do not execute remote command (usefull for just forwarding port)
#
# -R : Specifies that connections to the given TCP port or Unix socket on 
#      the remote (server) host are to be forwarded to the local side. 

set -o nounset                              # Treat unset variables as an error
set -euo pipefail                           # Bash Strict Mode	

reverse_ssh(){
    local ipServer="$1"
    local sshPort="$2"
    local remoteSSHPort="$3"
    local verbosity="$4"
    local -n outpid="$5"

    ssh -p $sshPort $verbosity -g -N -T -o "ServerAliveInterval 10" -o "ExitOnForwardFailure yes" \
	-R$remoteSSHPort:127.0.0.1:22 $ipServer &

    outpid=$!
}

# Read config file :
source utils/configparser.sh

load_reverse_ssh_server_config primary primary_ipServer primary_sshPort primary_remoteSSHPort primary_configured
load_reverse_ssh_server_config secondary secondary_ipServer secondary_sshPort secondary_remoteSSHPort secondary_configured

ssh_loglevel="$(parse_config "ssh_loglevel" config_static.ini)"

# Wait until we have connection with either the primary or secondary server
set +e
echo "[INFO]  Waiting for network..."
primary_ipServer_ip=$(cut -d "@" -f2 <<< $primary_ipServer)
secondary_ipServer_ip=$(cut -d "@" -f2 <<< $secondary_ipServer)
while true ; do
	if [[ -n "$primary_ipServer_ip" && -n "$primary_sshPort" ]] \
		&& nc -zw1 "$primary_ipServer_ip" "$primary_sshPort" >/dev/null 2>&1
	then
		echo "[INFO]  got response from the primary network server"
		break
	fi

	if [[ -n "$secondary_ipServer_ip" && -n "$secondary_sshPort" ]] \
		&& nc -zw1 "$secondary_ipServer_ip" "$secondary_sshPort" >/dev/null 2>&1
	then
		echo "[INFO]  got response from the secondary network server"
		break
	fi

	sleep 1
done

case $ssh_loglevel in

  DEBUG | DEBUG1)
	verbosity="-v"
    ;;

  DEBUG2)
	verbosity="-vv"
    ;;

  DEBUG3)
	verbosity="-vvv"
    ;;

  ERROR | *)
	verbosity=""
    ;;
esac

# Increase verbosity for every 10th service restart
if [[ "$((($(systemctl show hypernets-access.service -p NRestarts --value)+1)%10))" -eq 0 ]]; then
    verbosity="$verbosity -v"
fi

pids=()

if $primary_configured; then
    echo "[-> $primary_sshPort:]$primary_ipServer:$primary_remoteSSHPort"
    reverse_ssh "$primary_ipServer" "$primary_sshPort" "$primary_remoteSSHPort" "$verbosity" pid

    if kill -0 "$pid" 2>/dev/null; then
        echo "[INFO]  Primary tunnel started (PID $pid)"
        pids+=("$pid")
    else
        echo "[ERROR]  Primary tunnel failed"
    fi
else
	echo "[INFO]  Primary server is not configured"
fi

if $secondary_configured; then
    echo "[-> $secondary_sshPort:]$secondary_ipServer:$secondary_remoteSSHPort"
    reverse_ssh "$secondary_ipServer" "$secondary_sshPort" "$secondary_remoteSSHPort" "$verbosity" pid

    if kill -0 "$pid" 2>/dev/null; then
        echo "[INFO]  Secondary tunnel started (PID $pid)"
        pids+=("$pid")
    else
        echo "[ERROR]  Secondary tunnel failed"
    fi
else
	echo "[INFO]  Secondary server is not configured"
fi

# Wait only for tunnels that were started
if [ ${#pids[@]} -gt 0 ]; then
    wait "${pids[@]}"
fi
