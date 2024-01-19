#!/bin/bash - 
#===============================================================================
#
#          FILE: hello_server.sh
# 
#         USAGE: ./hello_server.sh 
# 
#   DESCRIPTION: Establish connection with server
#                Synchronize /config directory both ways
#                Set-up reverse ssh to make server able to access to host system
# 
#       OPTIONS: ---
#         NOTES: ---
#        AUTHOR: Alexandre CORIZZI, alexandre.corizzi@obs-vlfr.fr
#  ORGANIZATION: 
#       CREATED: 05/03/2020 15:53
#      REVISION: 23/10/2020 17:19
#s===============================================================================

set -o nounset                              # Treat unset variables as an error
set -euo pipefail                           # Bash Strict Mode	

# Make Logs
echo "Making Logs..."
mkdir -p LOGS

last_boot_timestamp=$(journalctl -b-1 -u hypernets-sequence --output-fields=__REALTIME_TIMESTAMP -o export | grep -m 1 __REALTIME_TIMESTAMP | sed -e 's/.*=//')
## truncate microseconds
last_boot_timestamp=${last_boot_timestamp::-6}

logNameBase=$(date +"%Y-%m-%d-%H%M" -d @$last_boot_timestamp)

if [ ! -d "ARCHIVE" ]; then
  echo "Creating archive directory..."
  mkdir ARCHIVE
fi

suffixeName=""
for i in {001..999}; do
	if [ -f "LOGS/$logNameBase$suffixeName-sequence.log" ]; then 
		echo "[DEBUG]  Error the log already exists! ($i)"
		suffixeName=$(echo "-$i")
	else
		logNameBase=$(echo $logNameBase$suffixeName)
		break
	fi
done


disk_usage() {
    logNameBase=$1

    echo "Disk usage informations:" 
    df -h -text4
	journalctl --disk-usage

    diskUsageOuput="LOGS/disk-usage.log"
    dfOutput=$(df -text4 --output=used,avail,pcent)

    if [ ! -f  $diskUsageOuput ] ; then
        echo "[INFO] Creation of $diskUsageOuput"
        echo -n "DateTime    " > $diskUsageOuput
        echo "$dfOutput" | sed 2d >> $diskUsageOuput
    fi
    echo -n "$logNameBase " >> $diskUsageOuput
    echo "$dfOutput" | sed 1d >> $diskUsageOuput
}

make_log() {
	logNameBase=$1
	logName=$2

	set +e
	systemctl is-enabled hypernets-$logName.service > /dev/null
	if [[ $? -eq 0 ]] ; then
		echo "[DEBUG]  Making log: $logNameBase-$logName..."
		journalctl -b-1 -u hypernets-$logName --no-pager > LOGS/$logNameBase-$logName.log
	else
		echo "[DEBUG]  Skipping log: $logName."
	fi
	set -e
}

remove_old_backups_from_archive() {
  sequence_count=$(find ARCHIVE/$1 -mindepth 3 -maxdepth 3  -depth -type d | wc -l)
  if [[ $sequence_count -gt 30 ]]; then
    nb_sequences_to_delete=$(("$sequence_count"-30))
    echo "Removing files from $1 older than 30 days..."
    find ARCHIVE/$1 -mindepth 3 -maxdepth 3  -depth -type d | sort -n | head -n $nb_sequences_to_delete | while read day_folder; do
      rm -r "$day_folder"
    done
    echo "Files from $1 older than 30 days have been removed correctly."
  fi
}

make_log $logNameBase sequence
make_log $logNameBase hello
make_log $logNameBase access
make_log $logNameBase webcam
disk_usage $logNameBase

# We check if network is on
echo "Waiting for network..."
nm-online
echo "Ok !"

# Read config file :
source utils/configparser.sh

ipServer=$(parse_config "credentials" config_static.ini)
remoteDir=$(parse_config "remote_dir" config_static.ini)
sshPort=$(parse_config "ssh_port" config_static.ini)
autoUpdate=$(parse_config "auto_update" config_dynamic.ini)

if [ -z $sshPort ]; then
	sshPort="22"
fi

if [ -z $autoUpdate ]; then
	autoUpdate="no"
fi

# We first make sure that server is up
set +e
for i in {1..30}
do
	# Update the datetime flag on the server
	echo "(attempt #$i) Touching $ipServer:$remoteDir/system_is_up"
	ssh -p $sshPort -t $ipServer "touch $remoteDir/system_is_up" > /dev/null 2>&1
	if [[ $? -eq 0 ]] ; then
		echo "Server is up!"
		break
	fi
	echo "Unsuccessful, sleeping 10s..."
	sleep 10
done
set -e

# Sync Config Files
source utils/bidirectional_sync.sh

bidirectional_sync "config_dynamic.ini" \
	"$ipServer" "$remoteDir/config_dynamic.ini.$USER" "$sshPort"

if [[ ! "$autoUpdate" == "no" ]] ; then
	echo "Auto Update ON"
	set +e
	git pull
	if [ $? -ne 0 ]; then echo "Can't pull : do you have local change ?" ; fi
	set -e
fi

# Copying files to archive directory
echo "Copying data to archive directory..."
for folderPath in DATA/*/; do
   if [[ "$folderPath" =~ ^DATA\/SEQ[0-9]{8}T[0-9]{6}/$ ]]; then
        year="${folderPath:8:4}"
        month="${folderPath:12:2}"
        day="${folderPath:14:2}"
        yearMonthDayArchive="ARCHIVE/DATA/$year/$month/$day"
        mkdir -p "$yearMonthDayArchive"
        cp -R "$folderPath" "$yearMonthDayArchive"
   fi
done

if [ -d LOGS ]; then
  echo "Copying logs to archive directory..."
  for fileLog in LOGS/*; do
     if [[ "$fileLog" =~ ^LOGS\/[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[a-z]+.log ]]; then
          year="${fileLog:5:4}"
          month="${fileLog:10:2}"
          day="${fileLog:13:2}"
          yearMonthDayArchive="ARCHIVE/LOGS/$year/$month/$day"
          mkdir -p "$yearMonthDayArchive"
          cp "$fileLog" "$yearMonthDayArchive"
     fi
  done
fi

remove_old_backups_from_archive "DATA"
remove_old_backups_from_archive "LOGS"

# Send data
echo "Syncing Data..."

rsync -e "ssh -p $sshPort" -rt --exclude "CUR*" --exclude "metadata.txt" \
	--remove-source-files "DATA" "$ipServer:$remoteDir"

if [ $? -eq 0 ]; then

	rsync -e "ssh -p $sshPort" -aim --exclude "CUR*" --include "*/" \
		--include "metadata.txt" --exclude "*" --remove-source-files "DATA" "$ipServer:$remoteDir" && \
  find DATA/ -mindepth 1 -depth -type d  -empty -exec rmdir {} \;

	if [ $? -eq 0 ]; then
		echo "[INFO] All data and metadata files have been successfully uploaded."
	else
		echo "[WARNING] Error during the uploading metadata process!"
	fi

else
	echo "[WARNING] Error during the uploading data process!"
fi

echo "Syncing Logs..."
rsync -e "ssh -p $sshPort" -rt --remove-source-files "LOGS" "$ipServer:$remoteDir" && \
find LOGS/ -mindepth 1 -depth -type d  -empty -exec rmdir {} \;

if [ -d "OTHER" ]; then
	echo "Syncing Directory OTHER..."
    # rt -> r XXX
   rsync --ignore-existing -e "ssh -p $sshPort" -r --remove-source-files "OTHER" "$ipServer:$remoteDir" && \
   find OTHER/ -mindepth 1 -depth -type d  -empty -exec rmdir {} \;
	# rsync -e "ssh -p $sshPort" -rt "OTHER" "$ipServer:$remoteDir"
fi

echo "End."
