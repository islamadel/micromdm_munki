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
# 2026-07-17 log skipped clients
# 2026-10-21 refactor: flock, no eval, devices read once, include cache,
#            credentials via temporary wgetrc, helper functions, history pruning
# 2026-10-21 wget --timeout=1, executed command printed in color
#
# requires: bash >= 4.4, flock, wget, plistutil, xargs, md5sum, base64, tac

# keep history entries for this many days (must be larger than the longest interval used in notes)
history_keep_days=400
# 1: a command that returned an error is recorded in the history anyway (no retry on next run)
# 0: a failed command is retried on the next run
record_failed=1
# maximum run time for current process in seconds
max_run_time=1800

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$SCRIPT_DIR" || exit 1

for tool in flock wget plistutil xargs md5sum base64 tac mktemp; do
	if ! command -v "$tool" > /dev/null; then
		echo "ERROR: required tool not found: $tool"
		exit 1
	fi
done

##########################################################################
# run one process only (flock, released automatically when the process ends)
##########################################################################
lock_file="$SCRIPT_DIR/.micromdm_munki.lock"
exec 9>>"$lock_file"
if ! flock -n 9; then
	IFS=: read -r lock_start lock_pid < "$lock_file"
	echo "WARNING: another process is already running: since: $(date -d @"${lock_start:-0}") pid: ${lock_pid:-unknown}"
	if [[ $lock_start =~ ^[0-9]+$ && $lock_pid =~ ^[0-9]+$ ]] \
		&& (( $(date +%s) >= lock_start + max_run_time )) \
		&& ps -p "$lock_pid" -o args= | grep -qF "$(basename "$0")"; then
		# older than max time: kill old process
		echo "process with pid: ${lock_pid} will be killed"
		kill -TERM "$lock_pid"
		sleep 5
		if kill -0 "$lock_pid" 2>/dev/null; then kill -KILL "$lock_pid"; sleep 2; fi
		flock -w 10 9 || { echo "ERROR: could not acquire lock"; exit 1; }
	else
		# max time not reached
		exit 0
	fi
fi
printf '%s:%s\n' "$(date +%s)" "$$" > "$lock_file"

tmp_dir=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp_dir"' EXIT
trap 'exit 130' INT TERM

##########################################################################
# settings
##########################################################################
source "$SCRIPT_DIR/settings/micromdm_settings"

if [ ! -f "$api_path/get_devices" ]; then
	echo "ERROR: api command not available"
	echo "run:"
	echo "$SCRIPT_DIR/download_micromdm_api_tools.sh"
	exit 1
fi

# color for the command that is executed (only on a terminal, or with FORCE_COLOR=1)
if [ -t 1 ] || [ -n "${FORCE_COLOR:-}" ]; then
	color_cmd=$'\033[1;36m'
	color_off=$'\033[0m'
else
	color_cmd=""
	color_off=""
fi

# characters removed from notes parameters
sanitize_pattern='[<>`$,;&|]'
sanitize() { local s=$1; printf '%s' "${s//$sanitize_pattern/}"; }

declare -A SRV_URL SRV_WGETRC SRV_WPARAMS
server_names=()
for d in "$SCRIPT_DIR"/settings/munki_servers/*/; do
	[ -f "${d}munki_settings" ] || continue
	name=$(basename "$d")
	# load settings in a subshell so variables do not leak between servers
	{
		IFS= read -r -d '' s_url
		IFS= read -r -d '' s_user
		IFS= read -r -d '' s_pass
		IFS= read -r -d '' s_wparams
	} < <(
		source "$SCRIPT_DIR/settings/micromdm_settings"
		source "${d}munki_settings"
		printf '%s\0' "$munki_server" "$munki_user" "$(printf '%s' "$munki_pass_enc" | base64 -d)" "${wget_params:-}"
	)
	# credentials go into a private temporary wgetrc, not onto the command line (visible in ps)
	rc_file="$tmp_dir/wgetrc_$name"
	( umask 077; printf 'http_user=%s\nhttp_password=%s\n' "$s_user" "$s_pass" > "$rc_file" )
	SRV_URL[$name]=$s_url
	SRV_WGETRC[$name]=$rc_file
	SRV_WPARAMS[$name]=$s_wparams
	server_names+=("$name")
done
unset s_url s_user s_pass s_wparams rc_file

if [ "${#server_names[@]}" -eq 0 ]; then
	echo "ERROR: no munki servers configured in $SCRIPT_DIR/settings/munki_servers"
	exit 1
fi
munki_count=${#server_names[@]}

##########################################################################
# state files
##########################################################################
clients_servers_list="./munki_servers/clients.log"
not_found_log="./skipped/clients_not_found.log"
mkdir -p ./munki_servers ./skipped/clients
touch "$clients_servers_list" "$not_found_log"

history_keep_min=$(( $(date +%s) / 86400 - history_keep_days ))
for name in "${server_names[@]}"; do
	mkdir -p "./munki_servers/$name/munki_manifests" "./munki_servers/$name/history"
	history_log="./munki_servers/$name/history/history.log"
	touch "$history_log"
	# prune old history entries (first field = days since epoch)
	awk -F: -v min="$history_keep_min" '($1 + 0) >= min' "$history_log" > "$history_log.tmp" \
		&& mv -f "$history_log.tmp" "$history_log"
done

# client -> "server:timestamp"
declare -A CLIENT_SRV
while IFS=: read -r c_sn c_srv c_ts; do
	[ -n "$c_sn" ] && CLIENT_SRV[$c_sn]="$c_srv:$c_ts"
done < "$clients_servers_list"

save_clients() {
	local k tmp="$clients_servers_list.tmp"
	for k in "${!CLIENT_SRV[@]}"; do
		printf '%s:%s\n' "$k" "${CLIENT_SRV[$k]}"
	done | sort > "$tmp" && mv -f "$tmp" "$clients_servers_list"
}

# remove all lines containing a fixed string: remove_lines <file> <string>
remove_lines() {
	[ -f "$1" ] || return 0
	grep -vF -- "$2" "$1" > "$1.tmp"
	mv -f "$1.tmp" "$1"
}

##########################################################################
# devices: read once (serial_number line is followed by the udid line)
##########################################################################
declare -A UDID
devices=()
while IFS=$'\t' read -r dev_sn dev_udid; do
	[ -n "$dev_sn" ] || continue
	devices+=("$dev_sn")
	UDID[$dev_sn]=$dev_udid
done < <("$api_path/get_devices" | awk -F'"' '/serial_number/ {s=$4; getline; print s "\t" $4}')

##########################################################################
# helpers
##########################################################################
# download from a munki server with credentials: fetch_auth <server> <url> <outfile>
fetch_auth() {
	local name=$1 url=$2 out=$3
	local -a args
	read -ra args <<< "${SRV_WPARAMS[$name]}"
	if WGETRC="${SRV_WGETRC[$name]}" wget "${args[@]}" --timeout=1 -O "$out.part" "$url" < /dev/null; then
		mv -f "$out.part" "$out"
	else
		rm -f "$out.part"
		return 1
	fi
}

# download without credentials: fetch_plain <server> <url> <outfile>
fetch_plain() {
	local name=$1 url=$2 out=$3
	local -a args
	read -ra args <<< "${SRV_WPARAMS[$name]}"
	if wget "${args[@]}" --timeout=1 -O "$out.part" "$url" < /dev/null; then
		mv -f "$out.part" "$out"
	else
		rm -f "$out.part"
		return 1
	fi
}

# download an included manifest once per run and extract its commands
# prepare_include <server> <include>  ->  commands file in $INC_CMDS
declare -A INC_STATE
prepare_include() {
	local name=$1 inc=$2 key="$1|$2"
	local file="./munki_servers/$name/munki_manifests/$inc"
	INC_CMDS="$tmp_dir/cmds/$name/$inc.cmds"
	if [ -n "${INC_STATE[$key]:-}" ]; then
		[ "${INC_STATE[$key]}" = ok ]
		return
	fi
	INC_STATE[$key]=fail
	if [[ $inc == *..* ]]; then
		echo "ERROR: invalid include name: $inc"
		return 1
	fi
	mkdir -p "$(dirname "$file")" "$(dirname "$INC_CMDS")"
	if ! fetch_auth "$name" "${SRV_URL[$name]}/manifests/$inc" "$file"; then
		echo "WARNING: could not download include: $inc"
		return 1
	fi
	plistutil -f xml -i "$file" | awk '/<key>notes/,/<\/string>/' | grep -v "<key>notes" \
		| sed 's/.*<string>//;s/<\/string>.*//' \
		| sed 's/&lt;/</g;s/&gt;/>/g;s/&quot;/"/g;s/&apos;/'"'"'/g;s/&amp;/\&/g' > "$INC_CMDS"
	INC_STATE[$key]=ok
}

# run a command only if it has not been run within <interval> days
# run_if_due <interval> <history_key> <command> [args...]
run_if_due() {
	local interval=$1 key=$2
	shift 2
	local today=$(( $(date +%s) / 86400 )) last rc=0
	last=$(grep -F -- ":$key:" "$history_log" | tail -1 | cut -d: -f1)
	[[ $last =~ ^[0-9]+$ ]] || last=0
	if (( today - last < interval )); then
		echo "$@"
		echo "This command has been already executed within the past $interval days : $(( today - last ))"
		return 0
	fi
	# the command that is going to be executed is printed in color
	echo "${color_cmd}EXEC: $*${color_off}"
	"$@" < /dev/null || { rc=$?; echo "WARNING: command failed (exit $rc): $*"; }
	if (( rc == 0 || record_failed )); then
		echo "$today:$key:$(date +%Y-%m-%d_%H-%M-%S)" >> "$history_log"
	fi
	sleep 2
}

# install_profile <sn> <udid> <server> <cmd> <interval> <api_cmd>
install_profile() {
	local sn=$1 udid=$2 name=$3 cmd=$4 interval=$5 api_cmd=$6
	local mobileconfig url profile_hash profile_id key
	mobileconfig=$(mktemp "$tmp_dir/profile.XXXXXX") || return

	if [[ $cmd == *"[url="* ]]; then
		url=${cmd##*\[url=}
		url=${url%%\]*}
		echo "url=$url"
		if [[ $url == "${SRV_URL[$name]%/}"/* ]]; then
			# url is on munki server and requires authentication
			fetch_auth "$name" "$url" "$mobileconfig"
		else
			fetch_plain "$name" "$url" "$mobileconfig"
		fi || { echo "ERROR: could not download profile: $url"; rm -f "$mobileconfig"; return; }
	else
		# profile is embedded as base64
		printf '%s' "${cmd##*\[udid\] }" | base64 -d > "$mobileconfig" 2>/dev/null \
			|| { echo "ERROR: could not decode embedded profile"; rm -f "$mobileconfig"; return; }
	fi
	if [ ! -s "$mobileconfig" ]; then
		echo "ERROR: empty profile"
		rm -f "$mobileconfig"
		return
	fi

	profile_hash=$(md5sum "$mobileconfig" | awk '{print $1}')
	profile_id=$(tac "$mobileconfig" | grep -B1 "PayloadIdentifier" | \
		grep -vE 'PayloadIdentifier|^--$' | head -1 | \
		sed 's/.*<string>//;s/<\/string>.*//')
	echo profile="$mobileconfig"
	echo profile_hash="$profile_hash"
	echo profile_id="$profile_id"

	if [ "$profile_id" == "com.github.micromdm.micromdm.enroll" ]; then
		# for enrollment profile dont check hash
		# because it is different for each download
		key="$sn:$udid:$api_cmd:$profile_id"
	else
		key="$sn:$udid:$api_cmd:$profile_id:$profile_hash"
	fi
	run_if_due "$interval" "$key" "$api_path/$api_cmd" "$udid" "$mobileconfig"
	rm -f "$mobileconfig"
}

# generic api command: <interval>:[api_path]/<command> <target> <parameters>
# run_generic <sn> <udid> <cmd> <interval> <api_cmd>
run_generic() {
	local sn=$1 udid=$2 cmd=$3 interval=$4 api_cmd=$5
	local first target para key
	local -a extra=() cmdline
	read -r first target para <<< "$cmd"
	target=${target//\[udid\]/"$udid"}
	target=${target//\[sn\]/"$sn"}
	para=${para//\[udid\]/"$udid"}
	para=${para//\[sn\]/"$sn"}
	target=$(sanitize "$target")
	para=$(sanitize "$para")

	cmdline=("$api_path/$api_cmd")
	[ -n "$target" ] && cmdline+=("$target")
	if [ -n "$para" ]; then
		key="$sn:$udid:$api_cmd:$para"
		# split parameters like a shell would (quotes work) without evaluating anything
		if ! printf '%s' "$para" | xargs -r printf '%s\0' > "$tmp_dir/args"; then
			echo "ERROR: cannot parse parameters: $para"
			return
		fi
		mapfile -d '' -t extra < "$tmp_dir/args"
		cmdline+=("${extra[@]}")
	else
		key="$sn:$udid:$api_cmd"
	fi
	run_if_due "$interval" "$key" "${cmdline[@]}"
}

# process one line of a notes field
# process_command <sn> <udid> <server> <cmd>
process_command() {
	local sn=$1 udid=$2 name=$3 cmd=$4
	local interval rest api_cmd

	if [[ "${cmd#*:}" == \[api_path* ]]; then
		# interval in days: first integer before delimiter :
		interval=${cmd%%:*}
		if [[ ! $interval =~ ^[0-9]+$ ]]; then
			echo "ERROR: invalid integer: $interval"
			return
		fi
		# all strings after first delimiter :
		rest=$(sanitize "${cmd#*:}")
		api_cmd=${rest#\[api_path\]/}
		api_cmd=${api_cmd%% \[*}
		api_cmd=${api_cmd%% *}
		if [ "$api_cmd" == "commands/install_profile" ]; then
			install_profile "$sn" "$udid" "$name" "$cmd" "$interval" "$api_cmd"
		else
			run_generic "$sn" "$udid" "$cmd" "$interval" "$api_cmd"
		fi
	elif [[ $cmd == \#* ]]; then
		echo "$cmd"
	else
		echo "$sn : $cmd: Invalid notes format"
		echo "must begin with n:[api_path] , n is number of days to re-run"
	fi
}

##########################################################################
# main
##########################################################################
for sn in "${devices[@]}"; do
	echo "##########################"
	echo sn="$sn"
	udid=${UDID[$sn]:-}
	skipped_log="./skipped/clients/$sn.log"
	clients_dirty=0

	for name in "${server_names[@]}"; do
		echo "Loading munki settings of: ${name}"
		history_log="./munki_servers/$name/history/history.log"

		# skip if client belongs to another munki server
		assoc=${CLIENT_SRV[$sn]:-}
		if [ -n "$assoc" ]; then
			if [ "${assoc%%:*}" == "$name" ]; then
				echo "$sn belongs to: ${name}"
			else
				echo "$sn does not belong to: ${name} skipping .."
				continue
			fi
		fi

		manifest="./munki_servers/$name/munki_manifests/$sn"
		if fetch_auth "$name" "${SRV_URL[$name]}/manifests/$sn" "$manifest"; then
			# client has been found, associate it to this server
			CLIENT_SRV[$sn]="$name:$(date +%s)"
			clients_dirty=1
			remove_lines "$skipped_log" ":$sn:$name:skipped:"
			remove_lines "$not_found_log" ":$sn:not found:"
		else
			# client not found on repo
			if [ -n "$assoc" ]; then
				unset "CLIENT_SRV[$sn]"
				clients_dirty=1
			fi
			# keep the first entry (= since when the client is missing)
			if ! grep -qF ":$sn:$name:skipped:" "$skipped_log" 2>/dev/null; then
				echo "$(( $(date +%s) / 86400 )):$sn:$name:skipped:$(date +%Y-%m-%d_%H-%M-%S)" >> "$skipped_log"
			fi
			continue
		fi

		if [ -z "$udid" ]; then
			echo "WARNING: no udid found for $sn, skipping commands"
			continue
		fi

		# micromdm included manifests
		while IFS= read -r inc; do
			[ -n "$inc" ] || continue
			echo inc="$inc"
			prepare_include "$name" "$inc" || continue
			while IFS= read -r cmd; do
				[ -n "$cmd" ] || continue
				process_command "$sn" "$udid" "$name" "$cmd"
			done < "$INC_CMDS"
		done < <(plistutil -f xml -i "$manifest" | grep micromdm | sed 's/.*<string>//;s/<\/string>.*//')
	done

	(( clients_dirty )) && save_clients

	# client missing on all munki servers: log once
	if [ -f "$skipped_log" ]; then
		skipped_servers=$(cut -d: -f3 "$skipped_log" | sort -u | wc -l)
		if (( skipped_servers >= munki_count )) && ! grep -qF ":$sn:not found:" "$not_found_log"; then
			echo "$(( $(date +%s) / 86400 )):$sn:not found:$(date +%Y-%m-%d_%H-%M-%S)" >> "$not_found_log"
		fi
	fi
done
echo done
