#!/bin/bash - 
#===============================================================================
#
#          FILE: bidirectional_sync.sh
# 
#         USAGE: ./bidirectional_sync.sh  localFile user@remote remoteFile
# 
#   DESCRIPTION: two-way sync between remote and local files
# 
#         NOTES: ---
#        AUTHOR: Alexandre CORIZZI, alexandre.corizzi@obs-vlfr.fr
#  ORGANIZATION: LOV
#       CREATED: 05/03/2020 14:32
#      REVISION:  ---
#s===============================================================================

set -o nounset                              # Treat unset variables as an error
set -euo pipefail                           # Bash Strict Mode	

bidirectional_sync(){
	local localPath="$1"
	local remoteAccess="$2"
	local remotePath="$3"
	local sshPort="$4"
	local server="$5"

	echo "[INFO]  ($server server) Sync files : $remoteAccess:$remotePath"
	echo "[INFO]  ($server server)        <->  $localPath"

	set +e  # Temporary allow error in script
	local remoteDate=$(ssh -p "$sshPort" -T "$remoteAccess" \
		"stat -c %y $remotePath 2> /dev/null")

	local retcode="$?"

	if [[ "$retcode" -eq 1 ]]; then
		echo "[INFO]  ($server server) $0 : Remote file does not exist, uploading now"
		scp -p -P "$sshPort" "$localPath" "$remoteAccess:$remotePath"
		return $?
	elif [[ "$retcode" -eq 255 || "$remoteDate" == "" ]]; then
		echo "[ERROR]  ($server server) Failed to retreive remote file modification time"
		return -1
	fi

	local localDate=$(stat -c %y "$localPath" 2> /dev/null)
	if [[ "$?" -eq 1 ]]; then
		echo "[INFO]  ($server server) $0 : Local file does not exist, downloading now"
		scp -p -P "$sshPort" "$remoteAccess:$remotePath" "$localPath"
		return $?
	fi
	set -e  # Back to strict mode

	# Conversion in integer
	local remoteTimeStamp=$(date -d "$remoteDate" +%s)
	local localTimeStamp=$(date -d "$localDate" +%s)

	# Both files exists, compare of datetimes and sync
	if [ "$remoteTimeStamp" -gt "$localTimeStamp" ] ; then
		echo "[INFO]  ($server server) Local date: $localDate"
		echo "[INFO]  ($server server) Remote date: $remoteDate"
		echo "[INFO]  ($server server) Sync from remote to local"
		rsync -e "ssh -p $sshPort" -vt "$remoteAccess:$remotePath" "$localPath"
	elif [ "$remoteTimeStamp" -lt "$localTimeStamp" ] ; then
		echo "[INFO]  ($server server) Local date: $localDate"
		echo "[INFO]  ($server server) Remote date: $remoteDate"
		echo "[INFO]  ($server server) Sync from local to remote"
		rsync -e "ssh -p $sshPort" -vt "$localPath" "$remoteAccess:$remotePath"
	else
		echo "[INFO]  ($server server) Files are synchronized."
	fi
	return $?
}
