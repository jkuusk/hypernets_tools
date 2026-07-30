#!/bin/bash -
#===============================================================================
#
#          FILE: configparser.sh
#
#         USAGE: source configparser.sh
#
#   DESCRIPTION: 
#       OPTIONS: ---
#        AUTHOR: Alexandre CORIZZI, alexandre.corizzi@obs-vlfr.fr
#  ORGANIZATION: Laboratoire d'oceanographie de Villefranche-sur-mer (LOV)
#       CREATED: 23/04/2021 09:26
#      REVISION:  ---
#===============================================================================

set -o nounset                              # Treat unset variables as an error
set -euo pipefail                           # Bash Strict Mode

parse_config () {
	keyword="$1"
	config_file="$2"

	if [[ ! -f "$config_file" ]]; then
		>&2 echo "Config file $config_file not found"
		exit -1
	fi

	value=$(awk -F "[=]" '/^'$keyword'/ {print $2; exit}' $config_file)
	value=$(echo "$value" | tr -d ' ')
	echo $value
}


load_data_server_config() {
    local prefix="$1"
    local -n ipServer="$2"
    local -n sshPort="$3"
    local -n remoteDir="$4"
	local -n configured="$5"

    ipServer=$(parse_config "${prefix}_server_credentials" config_static.ini)
    sshPort=$(parse_config "${prefix}_server_ssh_port" config_static.ini)
    remoteDir=$(parse_config "${prefix}_server_remote_dir" config_static.ini)

    if [[ "$prefix" == "primary" ]]; then
        : "${ipServer:=$(parse_config "credentials" config_static.ini)}"
        : "${sshPort:=$(parse_config "ssh_port" config_static.ini)}"
        : "${remoteDir:=$(parse_config "remote_dir" config_static.ini)}"
    fi

    : "${sshPort:=22}"

    configured=false
    [[ -n "$ipServer" && -n "$remoteDir" ]] && configured=true
}


load_reverse_ssh_server_config() {
    local prefix="$1"
    local -n ipServer="$2"
    local -n sshPort="$3"
    local -n remoteSSHPort="$4"
	local -n configured="$5"

    ipServer=$(parse_config "${prefix}_server_credentials" config_static.ini)
    sshPort=$(parse_config "${prefix}_server_ssh_port" config_static.ini)
    remoteSSHPort=$(parse_config "${prefix}_server_remote_ssh_port" config_static.ini)

    if [[ "$prefix" == "primary" ]]; then
        : "${ipServer:=$(parse_config "credentials" config_static.ini)}"
        : "${sshPort:=$(parse_config "ssh_port" config_static.ini)}"
        : "${remoteSSHPort:=$(parse_config "remote_ssh_port" config_static.ini)}"
    fi

    : "${sshPort:=22}"
    : "${remoteSSHPort:=20213}"

    configured=false
    [[ -n "$ipServer" && -n "$remoteSSHPort" ]] && configured=true
}
