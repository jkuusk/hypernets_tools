#!/bin/bash - 
#===============================================================================
#
#          FILE: hello_server.sh
# 
#         USAGE: ./hello_server.sh 
# 
#   DESCRIPTION: Generate logs
#                Establish connection with server
#                Synchronize config with server
#                Copy data, logs, webcam images to local archive
#                Upload data, logs, webcam images to server
# 
#        AUTHOR: Alexandre CORIZZI, alexandre.corizzi@obs-vlfr.fr
#       CREATED: 05/03/2020 15:53
#s===============================================================================

set -o nounset                              # Treat unset variables as an error
set -euo pipefail                           # Bash Strict Mode	

## set some global rsync parameters
rsync_chmod="--no-p --chmod=D755,F644"
rsync_loglevel="" # -i -v --dry-run"

if [[ ${PWD##*/} != "hypernets_tools"* ]]; then
	echo "This script must be run from hypernets_tools folder" 1>&2
	echo "Use : ./utils/${0##*/} instead"
	exit 1
fi

# add ~/.local/bin to path, Yocto command line API is installed there in Manjaro
PATH="$PATH:~/.local/bin"

# Make Logs
echo "[INFO]  Making Logs..."
set +e
last_boot_timestamp=$(journalctl -b-1 --output-fields=__REALTIME_TIMESTAMP -o export | grep -m 1 __REALTIME_TIMESTAMP | sed -e 's/.*=//')
set -e

## truncate microseconds
last_boot_timestamp=${last_boot_timestamp::-6}

logNameBase=$(date +"%Y-%m-%d-%H%M" -d @$last_boot_timestamp)
YMFolder=$(date +"%Y/%m" -d @$last_boot_timestamp)

## create LOG folder if it does not exist already
mkdir -p LOGS/$YMFolder/

if [ ! -d "ARCHIVE" ]; then
  echo "[INFO]  Creating archive directory..."
  mkdir ARCHIVE
fi

suffixeName=""
for i in {001..999}; do
	exists=false

	for type in sequence access webcam hello ; do
		if [ -f "LOGS/$YMFolder/${logNameBase}${suffixeName}-$type.log" ] || \
		   [ -f "ARCHIVE/LOGS/$YMFolder/${logNameBase}${suffixeName}-$type.log" ]; then
			exists=true
			break
		fi
	done

	if $exists; then
		echo "[WARNING]  The log already exists! ($i)"
		suffixeName="-$i"
	else
		logNameBase="${logNameBase}${suffixeName}"
		break
	fi
done


disk_usage() {
    echo "[INFO]  Disk usage information:" 
    df -h -text4
	journalctl --disk-usage

    local diskUsageOuput="LOGS/disk-usage.log"
    local dfOutput=$(df -text4 --output=used,avail,pcent)

    if [ ! -f  $diskUsageOuput ] ; then
        echo "[INFO]  Creation of $diskUsageOuput"
        echo -n "DateTime    " > $diskUsageOuput
        echo "$dfOutput" | sed 2d >> $diskUsageOuput
    fi
	echo -n "$(date +"%Y-%m-%d-%H%M") " >> $diskUsageOuput
    echo "$dfOutput" | sed 1d >> $diskUsageOuput
}


net_traffic() {
	## Parse vnstat jsonversion 2
	local net_db=$(vnstat --json)

	if [[ $(jq '.jsonversion' <<< $net_db | sed -e 's/"//g') != "2" ]]; then 
		echo "[ERROR]  Cannot parse vnstat JSON version $(jq '.jsonversion' <<< $net_db). Only version 2 is supported"
		return
	fi

	echo "[INFO]  Network traffic: (interface Tx / Rx MiB)"

	readarray -t interfaces < <(jq '.interfaces[].name' <<< $net_db | sed -e 's/"//g')

	readarray -t month_tx < <(jq '.interfaces[].traffic.month | last .tx' <<< $net_db)
	readarray -t month_rx < <(jq '.interfaces[].traffic.month | last .rx' <<< $net_db)
	local ym=$(paste -d "-" <(jq '.interfaces | first .traffic.month | last .date.year' <<< $net_db) \
			<(jq '.interfaces | first .traffic.month | last .date.month' <<< $net_db))

	readarray -t day_tx < <(jq '.interfaces[].traffic.day | last .tx' <<< $net_db)
	readarray -t day_rx < <(jq '.interfaces[].traffic.day | last .rx' <<< $net_db)
	local ymd=$(paste -d "-" <(jq '.interfaces | first .traffic.day | last .date.year' <<< $net_db) \
			<(jq '.interfaces | first .traffic.day | last .date.month' <<< $net_db) \
			<(jq '.interfaces | first .traffic.day | last .date.day' <<< $net_db))

	local monthly="$ym:"
	local daily="$ymd:"

	## Loop over interfaces
	local tx_mib rx_mib 
	for i in "${!interfaces[@]}"; do 
		tx_mib=$(printf "%.1f" $(bc <<< "(${month_tx[$i]}) / (1024 * 1024)"))
		rx_mib=$(printf "%.1f" $(bc <<< "(${month_rx[$i]}) / (1024 * 1024)"))
		monthly="$monthly ${interfaces[$i]} $tx_mib / $rx_mib;"

		tx_mib=$(printf "%.1f" $(bc <<< "(${day_tx[$i]}) / (1024 * 1024)"))
		rx_mib=$(printf "%.1f" $(bc <<< "(${day_rx[$i]}) / (1024 * 1024)"))
		daily="$daily ${interfaces[$i]} $tx_mib / $rx_mib;"
	done

    echo "[INFO]  $monthly"
    echo "[INFO]  $daily"

	## Warn if wwan interface is missing from vnstat, but it is available and radio is enabled
	if [[ $(jq '.interfaces[].name' <<< $net_db | grep -c -e wwa -e wwp) -eq 0 ]] && \
			[[ $(nmcli -t radio wwan | grep -c enabled) -ne 0 ]] && \
			[[ $(vnstat --iflist 1 | grep -c -e wwa -e wwp) -ne 0 ]]; then
		echo "[WARNING]  WWAN interface seems to be missing from the vnstat logs." \
				"Available interfaces are: $(vnstat --iflist 1 | tr '\n' ' ')"
	fi
}


make_log() {
	local logNameBase=$1
	local logName=$2
	shift 2 

	# get all remaining services to log
	local extra_services=""
	while [[ ! -z "${1-}" ]]; do
		extra_services="$extra_services -u $1 "
		shift 1
	done

	set +e
	systemctl is-enabled hypernets-$logName.service > /dev/null
	if [[ $? -eq 0 ]] ; then
		echo "[INFO]  Making log: $logNameBase-$logName"
		journalctl -b-1 -u hypernets-$logName $extra_services --no-pager --all > LOGS/$YMFolder/$logNameBase-$logName.log
	else
		echo "[INFO]  Skipping log: $logName"
	fi
	set -e
}


remove_old_backups_from_archive() {
	local folder="$1"
	local lvl=$2
	local keep=$3
	local sequence_count nb_sequences_to_delete

	if [ ! -d ARCHIVE/$folder ]; then 
		return
	fi

	sequence_count=$(find ARCHIVE/"$folder" -mindepth $lvl -maxdepth $lvl -depth -type d -not -empty | wc -l)

	if [[ $sequence_count -gt $keep ]]; then
		nb_sequences_to_delete=$(("$sequence_count"-$keep))
		echo "[INFO]  Removing files and folders from ARCHIVE/$folder, keeping $keep folders..."
		find ARCHIVE/$folder -mindepth $lvl -maxdepth $lvl -depth -type d -not -empty | sort -n | head -n $nb_sequences_to_delete | \
			while read day_folder; do
				rm -r "$day_folder"
				#echo "rm -r $day_folder"

				# remove empty folders
				find ARCHIVE/$folder -mindepth 1 -depth -type d -empty -delete
			done
		echo "[INFO]  Cleaned up ARCHIVE/$folder"
	fi
}


touch_server_is_up() {
    local server="$1"    # "primary" or "secondary"
    local ipServer="$2"
    local sshPort="$3"
    local remoteDir="$4"
	local yocto next_wakeup_timestamp yocto_offset retcode msg_txt utc_offset

    # If Yocto API is installed, write next scheduled wakeup time
    if [[ $(command -v YWakeUpMonitor) && $(command -v YRealTimeClock) ]]; then
        yocto=$(parse_config "yocto_prefix2" config_static.ini)
        if [[ -z "$yocto" ]]; then
            yocto=$(parse_config "yocto_prefix3" config_static.ini)
        fi

        next_wakeup_timestamp=$(YWakeUpMonitor -f '[result]' -r 127.0.0.1 "$yocto" get_nextWakeUp | sed -e 's/[[:space:]].*//')
        yocto_offset=$(YRealTimeClock -f '[result]' -r 127.0.0.1 "$yocto" get_utcOffset)
        retcode=$?

        if [[ $retcode -ne 0 ]]; then
            msg_txt="Yocto '$yocto' is not accessible!"
            echo "[ERROR]  $msg_txt"
        elif [[ "$next_wakeup_timestamp" = 0 ]]; then
            msg_txt="Yocto scheduled wakeup is disabled!"
        else
            if [[ "$yocto_offset" = 0 ]]; then
                utc_offset=""
            else
                utc_offset=$(printf "%+d" $((yocto_offset / 3600)))
            fi

            msg_txt="Next Yocto wakeup is scheduled on $(date -d "@$next_wakeup_timestamp" '+%Y/%m/%d %H:%M:%S') UTC$utc_offset"
        fi
    else
        msg_txt="Yocto API is not installed, can't read next scheduled wakeup"
    fi

    for i in {1..30}; do
        echo "[INFO]  ($server server, attempt #$i) Touching $ipServer:$remoteDir/system_is_up"

		ssh -p "$sshPort" -t $ipServer "echo \"$msg_txt\" > $remoteDir/system_is_up" > /dev/null 2>&1

        if [[ $? -eq 0 ]]; then
            echo "[INFO]  $server server is up!"
            return 0
        fi

        echo "[INFO]  ($server server, attempt #$i) Unsuccessful, sleeping 10s..."
        sleep 10
    done

    echo "[WARNING]  Failed to update system_is_up on the $server server."
    return 1
}


sync_data() {
	local server="$1"
	local sshPort="$2"
	local ipServer="$3"
	local remoteDir="$4"
	local rootFolder="${5%/}"

	echo "[INFO]  Syncing Data to $server server..."

	## first sync the SEQ folders without metadata.txt
	rsync -e "ssh -p $sshPort" -ram $rsync_loglevel $rsync_chmod --remove-source-files \
			--exclude "metadata.txt" --exclude "CUR*" \
			"$rootFolder/DATA" "$ipServer:$remoteDir"

	# then sync metadata.txt to indicate that the sequence 
	# has been completely transferred to the server
	if [ $? -eq 0 ]; then
		rsync -e "ssh -p $sshPort" -am $rsync_loglevel $rsync_chmod --remove-source-files --exclude "CUR*" --include "*/" \
			--include "metadata.txt" --exclude "*" "$rootFolder/DATA" "$ipServer:$remoteDir"

		if [ $? -eq 0 ]; then
			echo "[INFO]  All data and metadata files have been successfully uploaded to $server server."
		else
			echo "[WARNING]  Error while uploading metadata to $server server!"
		fi

	else
		echo "[WARNING]  Error while uploading data to $server server!"
	fi

	# finally sync only meteo.csv from CUR folders and delete the folders after successful transfer
	# exclude CUR folders from current day to avoid interfering with ongoing sequence
	echo "[INFO]  Syncing uncompled (CUR) sequence meteo.csv to $server server..."
	rsync -e "ssh -p $sshPort" -am $rsync_loglevel $rsync_chmod --remove-source-files \
			--exclude "SEQ*" --exclude "$(date +'CUR%Y%m%dT*')" --include "*/" \
			--include "meteo.csv" --exclude "*" "$rootFolder/DATA" "$ipServer:$remoteDir" && \
		find DATA -mindepth 1 -depth -type d -regextype posix-extended -regex ".*/CUR[0-9]{8}T[0-9]{6}" \
			\! -exec test -f '{}/meteo.csv' \; -exec rm -rf {} +

	# clean up empty folders, exclude CUR folders from current day
	find "$rootFolder/DATA/" -mindepth 1 -depth -type d -not -path "$(date +'$rootFolder/DATA/%Y/%m/%d')" -not -path "$(date +'*CUR%Y%m%dT*')" -empty -delete
}


sync_logs() {
	local server="$1"
	local sshPort="$2"
	local ipServer="$3"
	local remoteDir="$4"
	local rootFolder="${5%/}"

	echo "[INFO]  Syncing Logs to $server server..."

	## first sync only the auto-generated service logs and remove after sync
	rsync -e "ssh -p $sshPort" -am $rsync_loglevel $rsync_chmod --remove-source-files \
			-f'+ *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]-[a-z]*.log' \
			-f'+ *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9]-[a-z]*.log' \
			-f'+ */' -f'- *' "$rootFolder/LOGS" "$ipServer:$remoteDir" && \
		find "$rootFolder/LOGS/" -mindepth 1 -depth -type d -not -path "$rootFolder/LOGS/$YMFolder" -empty -delete

	## next sync all the remaining files and folders in LOGS/ without removing after sync
	rsync -e "ssh -p $sshPort" -am $rsync_loglevel $rsync_chmod "$rootFolder/LOGS" "$ipServer:$remoteDir"
}


sync_other() {
	local server="$1"
	local sshPort="$2"
	local ipServer="$3"
	local remoteDir="$4"
	local rootFolder="${5%/}"

	if [ -d "OTHER" ]; then
		echo "[INFO]  Syncing Directory OTHER to $server server..."

		## first sync only the auto-generated webcam images and remove after sync
		rsync -e "ssh -p $sshPort" -am $rsync_loglevel $rsync_chmod --remove-source-files \
				-f'+ *[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9].jpg' \
				-f'+ */' -f'- *' "$rootFolder/OTHER" "$ipServer:$remoteDir" && \
			find "$rootFolder/OTHER/" -mindepth 2 -depth -type d -not -path "$rootFolder/OTHER/WEBCAM_*/$YMFolder" -empty -delete

		## next sync all the remaining files and folders in OTHER/ without removing after sync
		rsync -e "ssh -p $sshPort" -am $rsync_loglevel $rsync_chmod "$rootFolder/OTHER" "$ipServer:$remoteDir"
	fi
}

############ end of functions ###########

make_log $logNameBase sequence
make_log $logNameBase hello systemd-timesyncd
make_log $logNameBase access ssh sshd
make_log $logNameBase webcam
disk_usage
net_traffic

# Read config file :
source utils/configparser.sh

load_data_server_config primary primary_ipServer primary_sshPort primary_remoteDir primary_configured
load_data_server_config secondary secondary_ipServer secondary_sshPort secondary_remoteDir secondary_configured

two_servers_configured=false
$primary_configured && $secondary_configured && two_servers_configured=true

autoUpdate=$(parse_config "auto_update" config_dynamic.ini)

if [ -z $autoUpdate ]; then
	autoUpdate="no"
fi

# Archive DATA
echo "[INFO]  Linking data to archive..."
for folderPath in $(find DATA -type d -regextype posix-extended -regex ".*/(CUR|SEQ)[0-9]{8}T[0-9]{6}"); do
	seqname=$(basename $folderPath)
	year="${seqname:3:4}"
	month="${seqname:7:2}"
	day="${seqname:9:2}"
	yearMonthDayArchive="ARCHIVE/DATA/$year/$month/$day/"

	mkdir -p "$yearMonthDayArchive"
	cp -Raulf "$folderPath" "$yearMonthDayArchive"
done

# Archive LOGS
echo "[INFO]  Linking logs to archive..."
for fileLog in $(find LOGS -type f -regextype posix-extended -regex ".*/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}(-[0-9]{3})?-[a-z]+.log"); do
  	year="${fileLog:5:4}"
  	month="${fileLog:10:2}"
  	yearMonthArchive="ARCHIVE/LOGS/$year/$month/"

  	mkdir -p "$yearMonthArchive"
	cp -aulf "$fileLog" "$yearMonthArchive"
done

# Archive Webcam images
echo "[INFO]  Linking webcam images to archive..."
for imgfile in $(find OTHER/ -type f -regextype posix-extended -regex "OTHER/WEBCAM_(SITE|SKY)/.*[0-9]{8}T[0-9]{6}.jpg"); do
	filename="$(basename $imgfile)"
	year="${filename:0:4}"
	month="${filename:4:2}"
	camfolder="$(awk -F/ '{print $2}' <<< $imgfile)"
	yearMonthArchive="ARCHIVE/OTHER/$camfolder/$year/$month/"

	mkdir -p "$yearMonthArchive"
	cp -aulf "$imgfile" "$yearMonthArchive"
done

set +e

# Link to secondary queue
if $two_servers_configured; then
	mkdir -p SECONDARY_QUEUE

	echo "[INFO]  Linking DATA to secondary queue..."
	cp -Raulf DATA/ SECONDARY_QUEUE/

	echo "[INFO]  Linking LOGS to secondary queue..."
	cp -Raulf LOGS/ SECONDARY_QUEUE/

	echo "[INFO]  Linking OTHER to secondary queue..."
	cp -Raulf OTHER/ SECONDARY_QUEUE/
fi

# Wait until we have connection with either the primary or secondary server
echo "[INFO]  Waiting for network..."
primary_ipServer_ip=$(cut -d "@" -f2 <<< $primary_ipServer)
secondary_ipServer_ip=$(cut -d "@" -f2 <<< $secondary_ipServer)
while true ; do
	if $primary_configured && nc -zw1 "$primary_ipServer_ip" "$primary_sshPort" >/dev/null 2>&1
	then
		echo "[INFO]  got response from the primary network server"
		break
	fi

	if $secondary_configured && nc -zw1 "$secondary_ipServer_ip" "$secondary_sshPort" >/dev/null 2>&1
	then
		echo "[INFO]  got response from the secondary network server"
		break
	fi

	sleep 1
done


if $primary_configured; then
    touch_server_is_up "primary" "$primary_ipServer" "$primary_sshPort" "$primary_remoteDir" &
fi

if $secondary_configured; then
    touch_server_is_up "secondary" "$secondary_ipServer" "$secondary_sshPort" "$secondary_remoteDir" &
fi
set -e

# Sync Config File
source utils/bidirectional_sync.sh

if $primary_configured; then
	bidirectional_sync "config_dynamic.ini" \
		"$primary_ipServer" "$primary_remoteDir/config_dynamic.ini.$USER" "$primary_sshPort" "primary"
fi

if $secondary_configured; then
	bidirectional_sync "config_dynamic.ini" \
		"$secondary_ipServer" "$secondary_remoteDir/config_dynamic.ini.$USER" "$secondary_sshPort" "secondary"
fi


# Auto-update hypernets_tools
if [[ "$autoUpdate" == "yes" ]] ; then
	echo "[INFO]  Auto Update ON"
	set +e
	git pull --ff-only
	if [ $? -ne 0 ]; then echo "[ERROR]  Can't pull : do you have local change ?" ; fi
	set -e
fi


if $two_servers_configured; then
    sync_data "primary" "$primary_sshPort" "$primary_ipServer" "$primary_remoteDir" "."
    sync_logs "primary" "$primary_sshPort" "$primary_ipServer" "$primary_remoteDir" "."
    sync_other "primary" "$primary_sshPort" "$primary_ipServer" "$primary_remoteDir" "."

    sync_data "secondary" "$secondary_sshPort" "$secondary_ipServer" "$secondary_remoteDir" "SECONDARY_QUEUE"
    sync_logs "secondary" "$secondary_sshPort" "$secondary_ipServer" "$secondary_remoteDir" "SECONDARY_QUEUE"
    sync_other "secondary" "$secondary_sshPort" "$secondary_ipServer" "$secondary_remoteDir" "SECONDARY_QUEUE"
elif $primary_configured; then
    sync_data "primary" "$primary_sshPort" "$primary_ipServer" "$primary_remoteDir" "."
    sync_logs "primary" "$primary_sshPort" "$primary_ipServer" "$primary_remoteDir" "."
    sync_other "primary" "$primary_sshPort" "$primary_ipServer" "$primary_remoteDir" "."

	echo "[INFO]  Secondary server is not configured"
elif $secondary_configured; then
	echo "[INFO]  Primary server is not configured"

    sync_data "secondary" "$secondary_sshPort" "$secondary_ipServer" "$secondary_remoteDir" "."
    sync_logs "secondary" "$secondary_sshPort" "$secondary_ipServer" "$secondary_remoteDir" "."
    sync_other "secondary" "$secondary_sshPort" "$secondary_ipServer" "$secondary_remoteDir" "."
else
    echo "[WARNING]  No upload server is configured."
	echo "[WARNING]  Skipping ARCHIVE cleanup!"
	exit 1
fi

## Clean up ARCHIVE
#
# Second parameter is level:
# no subfolders - 0
# YYYY - 1
# YYYY/MM - 2
# YYYY/MM/DD - 3
#
# Third parameter is how many to keep
#
# remove_old_backups_from_archive "FOLDER" level keep
remove_old_backups_from_archive "DATA" 3 30
remove_old_backups_from_archive "LOGS" 2 6
remove_old_backups_from_archive "OTHER/WEBCAM_SITE" 2 3
remove_old_backups_from_archive "OTHER/WEBCAM_SKY" 2 3


echo "[INFO]  End."
