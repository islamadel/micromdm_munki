#!/bin/bash
# Islam Adel
# run api commands from munki to micromdm
# 2024-06-12
# 2024-06-19
# 2024-06-23
# 2024-06-24 run every n days
# 2024-06-26 echo comments #
# 2024-07-16 vpp update
# 2024-07-17 para update, remove & and |
# 2024-07-18 remove , and ; and $ and ` and < and >
# 2025-01-21 multiple munki servers
# 2025-02-04 run one process only
# 2025-02-05 wget timeout
# 2025-02-06 associate clients to servers
# 2025-02-07 wget params
# 2025-03-26 sleep after command

lock_file="/tmp/micromdm_munki.lock"
# maximum run time for current process in seconds
max_run_time=1800

# run one process only
if [ -f "${lock_file}" ]; then
	echo "WARNING: process is locked"
	lock_file_start=$(cat "$lock_file" | awk -F: '{print $1}')
	lock_file_pid="$(cat "$lock_file" | awk -F: '{print $2}')"
	
	max_lock_file_life=$((${max_run_time} + ${lock_file_start}))

	if ps -q ${lock_file_pid} -o pid,command --no-headers; then
		# process is running
		if [ $(date +%s) -ge ${max_lock_file_life} ]; then
			#kill old process, older than max time
			echo "WARNING: another process is already running: since: $(date -d @${lock_file_start})"
			echo "process with pid: ${lock_file_pid} will be killed"
			kill -9 ${lock_file_pid}
			sleep 5
		else
			# exit max time not reached
			echo "WARNING: another process is already running: since: $(date -d @${lock_file_start})"
			exit
		fi
	else
		# continue lock file has no matching process
		echo "WARNING: lock file exists without a matching process!"
		sleep 5
	fi
fi

echo "$(date +%s):$$" > "${lock_file}"

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SCRIPT_DIR"

source "$SCRIPT_DIR/settings/micromdm_settings"

if [ ! -f "$api_path/get_devices" ]; then
	echo "ERROR: api command not available"
	echo "run:"
	echo "$SCRIPT_DIR/download_micromdm_api_tools.sh"
	exit
fi
	
#download manifests connected with mdm
for sn in $($api_path/get_devices | grep serial_number| awk -F'"' '{print $4}'); do
	echo "##########################"
	echo sn="$sn"

	for munki_setting in $(ls -1 "$SCRIPT_DIR/settings/munki_servers"); do

		echo "Loading munki settings of: ${munki_setting}"

		source "$SCRIPT_DIR/settings/munki_servers/${munki_setting}/munki_settings"
		
		mkdir -p "./munki_servers/${munki_setting}/munki_manifests"
		mkdir -p "./munki_servers/${munki_setting}/micromdm_profiles"
		mkdir -p "./munki_servers/${munki_setting}/history"
		history_log="./munki_servers/${munki_setting}/history/history.log"
		clients_servers_list="./munki_servers/clients.log"
		touch "$history_log"
		touch "${clients_servers_list}"

		if grep -q "$sn" "${clients_servers_list}"; then
			# client has been associated before to munki_setting
			if ! grep -q "$sn:${munki_setting}:" "${clients_servers_list}"; then
				# client already exists for a certain munki setting
				echo "$sn does not belong to: ${munki_setting} . skipping .."
				continue
			fi
		fi

		wget ${wget_params} --timeout=3 --user ${munki_user} --password $(echo $munki_pass_enc | base64 -d) \
		-O "./munki_servers/${munki_setting}/munki_manifests/$sn" "${munki_server}/manifests/$sn"
		for inc in $(plistutil -f xml -i ./munki_servers/${munki_setting}/munki_manifests/$sn | \
		grep micromdm | sed 's/.*<string>//;s/<\/string>.*//'); do
			echo inc="$inc"
			#download micromdm included manifets
			mkdir -p ./munki_servers/${munki_setting}/munki_manifests/$(dirname $inc)
			wget ${wget_params} --timeout=3 --user ${munki_user} --password $(echo $munki_pass_enc | base64 -d) \
			-O "./munki_servers/${munki_setting}/munki_manifests/$inc" "${munki_server}/manifests/$inc"
	
			IFS_backup=$IFS
			IFS=$'\n'
	
			#execute micromdm api command
			for cmd in $(plistutil -f xml -i ./munki_servers/${munki_setting}/munki_manifests/$inc | \
			awk '/<key>notes/,/<\/string>/' | grep -v "<key>notes" \
			| sed 's/.*<string>//;s/<\/string>.*//'); do

				#client has been found, add to clients servers list
				#remove entry if exists
				sed -i "/${sn}:/d" "${clients_servers_list}"
				echo "${sn}:${munki_setting}:$(date '+%s')" >> "${clients_servers_list}"

				#all strings after first delimiter :
				if echo "$cmd" | cut -d ":" -f2- | grep -q "^\[api_path"; then
					last_run=365
					current_day=$(( $(date '+%s') / 86400 ))
					#interval in days first integer before delimiter :
					interval=$(echo "$cmd" | cut -d ":" -f1)
					if [ "$interval" -eq "$interval" ]; then
						echo "OK: valid integer"
					else
						echo "ERROR: invalid integer"
						continue 1
					fi
					#api command
					api_cmd="$(echo "$cmd" | sed 's/<//g' | sed 's/>//g' | sed 's/`//g' | sed 's/\$//g' | sed 's/,//g' | sed 's/;//g' | sed 's/&//g' | sed 's/|//g' | cut -d ":" -f2- | \
					sed 's/\[api_path\]\///;s/ \[.*//')"
					#get udid
					udid=$($api_path/get_devices | grep -A1 "$sn" | \
					grep -v "$sn" | awk -F'"' '{print $4}')
					echo udid=$udid
					for run in $(echo "$cmd" | sed 's/\[api_path\]/$api_path/g'); do
	
						if [ "$api_cmd" == "commands/install_profile" ]; then
	
							if echo "$cmd" | grep -F -q "[url="; then
								url="$(echo "$cmd" | sed 's/.*\[url=//;s/\].*//')"
								echo "url=$url"
								rn="$RANDOM"
								if echo "$url" | grep -q "$munki_server"; then
									#url is on munki server and requires authentication
									wget ${wget_params} --timeout=3 --user ${munki_user} \
									--password $(echo $munki_pass_enc | base64 -d) \
									-O "./munki_servers/${munki_setting}/micromdm_profiles/URL_$rn.mobileconfig" "$url"
								else
									wget ${wget_params} --timeout=3 -O "./munki_servers/${munki_setting}/micromdm_profiles/URL_$rn.mobileconfig" "$url"
								fi
								mobileconfig="./munki_servers/${munki_setting}/micromdm_profiles/URL_$rn.mobileconfig"
							else
								#file and file hash
								mobileconfig="./munki_servers/${munki_setting}/micromdm_profiles/$RANDOM.mobileconfig"
								echo "$cmd" | sed 's/.*\[udid\] //' | base64 -d >>"$mobileconfig"
							fi
							profile="$mobileconfig"
							profile_hash="$(md5sum "$mobileconfig" | awk '{print $1}')"
							profile_id="$(tac "$mobileconfig" | grep -B1 "PayloadIdentifier" | \
							grep -vE 'PayloadIdentifier|^--$' | head -1 | \
							sed 's/.*<string>//;s/<\/string>.*//')"
							echo profile=$profile
							echo profile_hash="$profile_hash"
							echo profile_id=$profile_id
	
							# for enrollment profile dont check hash
							# because it is different for each download
							if [ "$profile_id" == "com.github.micromdm.micromdm.enroll" ]; then
								last_run=$(grep -F "$sn:$udid:$api_cmd:$profile_id" \
								"$history_log" | tail -1 | cut -d ":" -f1)
								if [ "$last_run" -eq "$last_run" ]; then
									echo last_run=$last_run
								else
									last_run=365
								fi
								if [ "$(( $current_day - $last_run ))" -lt "$interval" ]; then
									echo "This command has been already executed within the past $interval days : $(( $current_day - $last_run ))"
								else
									echo "$api_path/$api_cmd" $udid $profile
									"$api_path/$api_cmd" $udid $profile
									sleep 2
									# days since epoch
									echo "$(( $(date '+%s') / 86400 )):$sn:$udid:$api_cmd:$profile_id:$(date +%Y-%m-%d_%H-%M-%S)" >>"$history_log"
								fi
							else
								last_run=$(grep -F "$sn:$udid:$api_cmd:$profile_id:$profile_hash" "$history_log" | tail -1 | cut -d ":" -f1)
								if [ "$last_run" -eq "$last_run" ]; then echo last_run=$last_run; else last_run=365; fi
								if [ "$(( $current_day - $last_run ))" -lt "$interval" ]; then
									echo "This command has been already executed within the past $interval days : $(( $current_day - $last_run ))"
								else
									echo "$api_path/$api_cmd" $udid $profile
									"$api_path/$api_cmd" $udid $profile
									sleep 2
					
									echo "$(( $(date '+%s') / 86400 )):$sn:$udid:$api_cmd:$profile_id:$profile_hash:$(date +%Y-%m-%d_%H-%M-%S)" >>"$history_log"
								fi
							fi
							rm "$mobileconfig"
						else
							para=""
						#	para="$(echo "$cmd" | sed 's/.*\[udid\]//' | sed 's/.*\[sn\]//')"
							para=$(echo "$cmd" | cut -d " " -f 3- |\
							sed 's/\[udid\]/'$udid'/g' | sed 's/\[sn\]/'$sn'/g' | sed 's/<//g' | sed 's/>//g' | sed 's/`//g' | sed 's/\$//g' | sed 's/,//g' | sed 's/;//g' | sed 's/&//g' | sed 's/|//g')
							target=$(echo "$cmd" | awk -F" " '{print $2}' | \
							sed 's/\[udid\]/'$udid'/g' | sed 's/\[sn\]/'$sn'/g' | sed 's/<//g' | sed 's/>//g' | sed 's/`//g' | sed 's/\$//g' | sed 's/,//g' | sed 's/;//g' | sed 's/&//g' | sed 's/|//g')
							if [ "$para" == "" ]; then
								last_run=$(grep -F "$sn:$udid:$api_cmd" "$history_log" | \
								tail -1 | cut -d ":" -f1)
								if [ "$last_run" -eq "$last_run" ]; then
									echo last_run=$last_run
								else
									last_run=365
								fi
								echo "$api_path/$api_cmd" $target
								if [ "$(( $current_day - $last_run ))" -lt "$interval" ]; then
									echo "This command has been already executed within the past $interval days : $(( $current_day - $last_run ))"
								else
									echo "$(( $(date '+%s') / 86400 )):$sn:$udid:$api_cmd:$(date +%Y-%m-%d_%H-%M-%S)" >>"$history_log"
									eval "$api_path/$api_cmd" $target
									sleep 2
								fi
							else
								#remove leading space
								para="$(echo "$para" | sed 's/^ *//')"
								last_run=$(grep -F "$sn:$udid:$api_cmd:$para" "$history_log" | \
								tail -1 | cut -d ":" -f1)
								if [ "$last_run" -eq "$last_run" ]; then
									echo last_run=$last_run
								else
									last_run=365
								fi
								echo "$api_path/$api_cmd" $target ${para}
								if [ "$(( $current_day - $last_run ))" -lt "$interval" ]; then
									echo "This command has been already executed within the past $interval days : $(( $current_day - $last_run ))"
								else
									echo "$(( $(date '+%s') / 86400 )):$sn:$udid:$api_cmd:$para:$(date +%Y-%m-%d_%H-%M-%S)" >>"$history_log"
									eval "$api_path/$api_cmd" $target $para
									sleep 2
								fi
							fi
						fi
					done
				elif echo "$cmd" | grep -q "^#"; then
					echo "$cmd"
				else
					echo "$sn : $cmd: Invalid notes format"
					echo "must begin with n:[api_path] , n is number of days to re-run"
				fi
			done
			IFS=$IFS_backup
		done
	done
done
sleep 5
if [ -f "${lock_file}" ]; then rm -f "${lock_file}"; fi
sleep 5
