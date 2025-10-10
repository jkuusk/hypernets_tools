#!/usr/bin/bash

set -o nounset                              # Treat unset variables as an error
set -euo pipefail                           # Bash Strict Mode


if [[ ${PWD##*/} != "hypernets_tools"* ]]; then
	echo "This script must be run from hypernets_tools folder" 1>&2
	echo "Use : ./utils/${0##*/} instead"
	exit 1
fi

if [[ "${1-}" == "-h" ]] || [[ "${1-}" == "--help" ]]; then
	echo "$0 [-h|--help]"
	echo
	echo "Show Yocto debug information"
	echo
	echo "  -h, --help   print this help"
	echo 
	exit 
fi

# add ~/.local/bin to path, Yocto command line API is installed there in Manjaro
PATH="$PATH:~/.local/bin"

source utils/configparser.sh

# Hypstar Configuration:
relay_board_prefix=$(parse_config "yocto_prefix1" config_static.ini)
gps_board_prefix=$(parse_config "yocto_gps" config_static.ini)
yoctoPrefix=$(parse_config "yocto_prefix2" config_static.ini)
if [[ "$yoctoPrefix" == "" ]]; then
# host system V4 or newer
    yoctoPrefix=$(parse_config "yocto_prefix3" config_static.ini)
	is_yocto_pictor_wifi=0
else
	is_yocto_pictor_wifi=1
fi

# check if Yocto command line API is installed
if [[ ! $(command -v YModule) ]]; then
	echo "[ERROR]  Yocto command line API is not installed"
	return 0
fi

set +e
last_boot_timestamp=$(journalctl -b --output-fields=__REALTIME_TIMESTAMP -o export | grep -m 1 __REALTIME_TIMESTAMP | sed -e 's/.*=//')
set -e

## truncate microseconds
last_boot_timestamp=${last_boot_timestamp::-6}

logNameBase=$(date +"%Y-%m-%d-%H%M" -d @$last_boot_timestamp)
YMFolder=$(date +"%Y/%m" -d @$last_boot_timestamp)

## create LOG folder if it does not exist already
mkdir -p LOGS/$YMFolder/

suffixeName=""
for i in {001..999}; do
	if [ -f "LOGS/$YMFolder/${logNameBase}${suffixeName}-yocto.log" ] || \
	   [ -f "ARCHIVE/LOGS/$YMFolder/${logNameBase}${suffixeName}-yocto.log" ]; then
		echo "[WARNING]  Yocto log already exists! ($i)"
		suffixeName="-$i"
	else
		logNameBase="${logNameBase}${suffixeName}"
		break
	fi
done

filename="LOGS/$YMFolder/${logNameBase}-yocto.log"
echo "[INFO]  Saving Yocto debug info into $filename"

echo "----- inventory -----" > "$filename" 2>&1
YModule -r 127.0.0.1 inventory >> "$filename" 2>&1

echo >> "$filename"
echo "----- showDebugInformation -----" >> "$filename" 2>&1
YModule -r 127.0.0.1 showDebugInformation >> "$filename" 2>&1

## Gen 1 yocto
if [[ "$is_yocto_pictor_wifi" == 1 ]]; then
	## Gen 1 yocto relay board api.txt
	url="http://127.0.0.1:4444/bySerial/$yoctoPrefix/$relay_board_prefix/api.txt"
	echo >> "$filename"
	echo "----- $url -----" >> "$filename" 2>&1
	wget -q -O- "$url" >> "$filename" 2>&1

	## Gen 1 yocto relay board logs.txt
	url="http://127.0.0.1:4444/bySerial/$yoctoPrefix/$relay_board_prefix/logs.txt"
	echo >> "$filename"
	echo "----- $url -----" >> "$filename" 2>&1
	wget -q -O- "$url" >> "$filename" 2>&1

	## Gen 1 yocto GPS api.txt
	url="http://127.0.0.1:4444/bySerial/$yoctoPrefix/$gps_board_prefix/api.txt"
	echo >> "$filename"
	echo "----- $url -----" >> "$filename" 2>&1
	wget -q -O- "$url" >> "$filename" 2>&1

	## Gen 1 yocto GPS logs.txt
	url="http://127.0.0.1:4444/bySerial/$yoctoPrefix/$gps_board_prefix/logs.txt"
	echo >> "$filename"
	echo "----- $url -----" >> "$filename" 2>&1
	wget -q -O- "$url" >> "$filename" 2>&1

	## Gen 1 yocto GPS comms logs
	url="http://127.0.0.1:4444/bySerial/$yoctoPrefix/$gps_board_prefix/rxmsg.json?dir=2"
	echo >> "$filename"
	echo "----- $url -----" >> "$filename" 2>&1
	wget -q -O- "$url" >> "$filename" 2>&1
else
	## Gen 2 yocto GPS comms logs
	echo >> "$filename"
	echo "----- download rxmsg.json?dir=2 -----" >> "$filename"  2>&1
	YModule -r 127.0.0.1 $yoctoPrefix download rxmsg.json?dir=2 >> "$filename" 2>&1
fi
