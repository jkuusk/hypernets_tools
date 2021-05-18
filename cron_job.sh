#!/bin/bash

## kill previous instance, if any
tmp=$(ps -o pid -C $(basename $0))
prev_pid=$(echo $tmp | tail -n +2 | grep -v $$ | sed -e 's/[^0-9]*//g')
if [ -n "$prev_pid" ]
then
	echo "ERROR: killing previous instance $prev_pid"

	kill $prev_pid
	pkill -P $prev_pid

	## power cycle pan/tilt and radiometer
	cd /home/joel/github/hypernets_tools_main
	python -m hypernets.scripts.relay_command -n2 -soff
	python -m hypernets.scripts.relay_command -n3 -soff

	sleep 10
fi

## try up to 2 times
#for i in {1..2}
#do
	cd /home/joel/github/hypernets_tools_main

	## create log file name and link /home/joel/logtmp/run_service_latest.log to the new file
	logfile=$(mktemp /home/joel/logtmp/run_service_XXXXX.log)
	rm /home/joel/logtmp/run_service_latest.log
	ln -s $logfile /home/joel/logtmp/run_service_latest.log
	
	date > $logfile

	sync

	## run service
	stdbuf -o0 -e0 /home/joel/github/hypernets_tools_main/run_service.sh >> $logfile 2>&1 
	
	sync

	## move log file to data folder
	## NB! This will probably fail if someone pokes the contents of /home/joel/github/hypernets_tools/DATA/
	## while the stcript is running
	dir=$(ls -1td /home/joel/github/hypernets_tools_main/DATA/* | head -n 1)
	chmod o+r $logfile
	mv -f $logfile $dir

	sync

#	## break if success
#	if [ $(basename $dir | grep -c SEQ) -eq 1 ]
#	then
#		break
#	fi
#	
#	## switch off relays in case service crashed
#	cd /home/joel/github/hypernets_tools_main
#	python -m hypernets.scripts.relay_command -n2 -soff
#	python -m hypernets.scripts.relay_command -n3 -soff
#	#python -m hypernets.scripts.relay_command -n6 -soff
#
#	sleep 10
#done
