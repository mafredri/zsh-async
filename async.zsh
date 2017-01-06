#!/usr/bin/env zsh

#
# zsh-async
#
# version: 1.3.1
# author: Mathias Fredriksson
# url: https://github.com/mafredri/zsh-async
#

# Produce debug output from zsh-async when set to 1.
ASYNC_DEBUG=${ASYNC_DEBUG:-0}

# Wrapper for jobs executed by the async worker, gives output in parseable format with execution time
_async_job() {
	# Disable xtrace as it would mangle the output.
	setopt localoptions noxtrace

	# Store start time as double precision (+E disables scientific notation)
	float -F duration=$EPOCHREALTIME

	# Run the command
	#
	# What is happening here is that we are assigning stdout, stderr and ret to
	# variables, and then we are printing out the variable assignment through
	# typeset -p. This way when we run eval we get something along the lines of:
	# 	eval "
	# 		typeset stdout=' M async.test.sh\n M async.zsh'
	# 		typeset ret=0
	# 		typeset stderr=''
	# 	"
	unset stdout stderr ret
	eval "$(
		{
			stdout="$(eval "$@")"
			ret=$?
			typeset -p stdout ret
		} 2> >(stderr="$(cat)"; typeset -p stderr)
	)"

	# Calculate duration
	duration=$(( EPOCHREALTIME - duration ))

	# if ret is missing for some unknown reason, set it to -1 to indicate we
	# have run into a bug
	ret=${ret:--1}

	# Grab mutex lock, stalls until token is available
	read -ep >/dev/null

	# Return output (<job_name> <return_code> <stdout> <duration> <stderr>$'\0')
	print -u3 -r -n -- "$1" "$ret" "${(q)stdout}" "$duration" "${(q)stderr}"$'\0'

	# Unlock mutex by inserting a token
	print -p "t"
}

# The background worker manages all tasks and runs them without interfering with other processes
_async_worker() {
	# Reset all options to defaults inside async worker.
	emulate -R zsh

	# Redirect stderr to /dev/null in case unforseen
	# errors produced by the worker. For example:
	#   fork failed: resource temporarily unavailable.
	exec 2>/dev/null

	local -A storage
	local unique=0
	local notify_parent=0
	local parent_pid=0
	local coproc_pid=0
	local processing=0

	# Deactivate all zsh hooks inside the worker.
	zsh_hooks=(chpwd periodic precmd preexec zshexit zshaddhistory)
	unfunction $zsh_hooks &>/dev/null
	# And hooks with registered functions.
	zsh_hook_functions=( ${^zsh_hooks}_functions )
	unset $zsh_hook_functions

	child_exit() {
		local pids
		pids=(${${(v)jobstates##*:*:}%\=*})

		# If coproc (cat) is the only child running, we close it to avoid
		# leaving it running indefinitely and cluttering the process tree.
		if  (( ! processing )) && [[ $#pids = 1 ]] && [[ $coproc_pid = $pids[1] ]]; then
			coproc :
			coproc_pid=0
		fi

		# On older version of zsh (pre 5.2) we notify the parent through a
		# SIGWINCH signal because `zpty` did not return a file descriptor (fd)
		# prior to that.
		if (( notify_parent )); then
			# We use SIGWINCH for compatibility with older versions of zsh
			# (pre 5.1.1) where other signals (INFO, ALRM, USR1, etc.) could
			# cause a deadlock in the shell under certain circumstances.
			kill -WINCH $parent_pid
		fi
	}

	# Register a SIGCHLD trap to handle the completion of child processes.
	trap child_exit CHLD

	# Process option parameters passed to worker
	while getopts "np:u" opt; do
		case $opt in
			n) notify_parent=1;;
			p) parent_pid=$OPTARG;;
			u) unique=1;;
		esac
	done

	# Wait for jobs sent by async_job.
	typeset -a cmd
	while read -d $'\0' -r request; do
		# Parse the request using shell parsing (z) to allow commands
		# to be parsed from single strings and multi-args alike.
		cmd=("${(z)request}")

		# Name of the job (first argument).
		local job=$cmd[1]

		# Check for non-job commands sent to worker
		case $job in
			_unset_trap)
				notify_parent=0; continue;;
			_killjobs)
				trap '' TERM    # Capture SIGTERM.
				kill -TERM -$$  # Send to entire process group.
				trap - TERM     # Reset local trap.
				coproc :        # Quit coproc.
				coproc_pid=0    # Reset pid.
				continue
				;;
		esac

		# If worker should perform unique jobs
		if (( unique )); then
			# Check if a previous job is still running, if yes, let it finnish
			for pid in ${${(v)jobstates##*:*:}%\=*}; do
				if [[ ${storage[$job]} == $pid ]]; then
					continue 2
				fi
			done
		fi

		# Guard against closing coproc from trap before command has started.
		processing=1

		# Because we close the coproc after the last job has completed, we must
		# recreate it when there are no other jobs running.
		if (( ! coproc_pid )); then
			# Use coproc as a mutex for synchronized output between children.
			coproc cat
			coproc_pid="$!"
			# Insert token into coproc
			print -p "t"
		fi

		# Run job in background, disable stdout/stderr and use fd 3 for result.
		_async_job $cmd 3>&1 1>/dev/null 2>&1 &
		# Store pid because zsh job manager is extremely unflexible (show jobname as non-unique '$job')...
		storage[$job]="$!"

		processing=0  # Disable guard.
	done
}

#
#  Get results from finnished jobs and pass it to the to callback function. This is the only way to reliably return the
#  job name, return code, output and execution time and with minimal effort.
#
# usage:
# 	async_process_results <worker_name> <callback_function>
#
# callback_function is called with the following parameters:
# 	$1 = job name, e.g. the function passed to async_job
# 	$2 = return code
# 	$3 = resulting stdout from execution
# 	$4 = execution time, floating point e.g. 2.05 seconds
# 	$5 = resulting stderr from execution
#
async_process_results() {
	setopt localoptions noshwordsplit

	integer count=0
	local worker=$1
	local callback=$2
	local caller=$3
	local -a items
	local line

	# Read output from zpty and parse it if available. Note that reading output
	# from zpty with a pattern is limited to one megabyte, if the pattern is
	# not encountered before the limit, the exit status will be non-zero.
	while zpty -r -m -t $worker line \*$'\0'\* 2>/dev/null; do
		line=${line[1,$#line-1]}        # Remove trailing NULL character.
		line=${line//$'\r'$'\n'/$'\n'}  # Remove unwanted "\r" from output.

		items=("${(@Q)${(z)line}}")

		# Due to how zpty pattern matching works, we should not encounter
		# this condition. However, we check it anyway as a precaution.
		if (( ${#items} != 5 )); then
			print -u2 $EPOCHREALTIME
			print -u2 "zsh-async:error: expected 5 items, got ${#items} (${(qqqq)items})"
			return 2
		fi

		$callback "${(@)items}"

		return 0
	done

	# Avoid printing exit value from setopt printexitvalue
	[[ $caller = trap || $caller = watcher ]] && return 0

	# No results were processed
	return 1
}

# Watch worker for output
_async_zle_watcher() {
	setopt localoptions noshwordsplit
	typeset -gA ASYNC_PTYS ASYNC_CALLBACKS
	local worker=$ASYNC_PTYS[$1]
	local callback=$ASYNC_CALLBACKS[$worker]

	if [[ -n $callback ]]; then
		async_process_results $worker $callback watcher
	fi
}

#
# Start a new asynchronous job on specified worker, assumes the worker is running.
#
# usage:
# 	async_job <worker_name> <my_function> [<function_params>]
#
async_job() {
	setopt localoptions noshwordsplit

	local worker=$1; shift

	local -a cmd
	cmd=("$@")
	if [[ ${#cmd} -gt 1 ]]; then
		# Quote special characters in multi argument commands.
		cmd=(${(q)cmd})
	fi

	zpty -w $worker "$cmd"$'\0'
}

# This function traps notification signals and calls all registered callbacks
_async_notify_trap() {
	setopt localoptions noshwordsplit

	for k in ${(k)ASYNC_CALLBACKS}; do
		async_process_results $k ${ASYNC_CALLBACKS[$k]} trap
	done
}

#
# Register a callback for completed jobs. As soon as a job is finnished, async_process_results will be called with the
# specified callback function. This requires that a worker is initialized with the -n (notify) option.
#
# usage:
# 	async_register_callback <worker_name> <callback_function>
#
async_register_callback() {
	setopt localoptions noshwordsplit nolocaltraps

	typeset -gA ASYNC_CALLBACKS
	local worker=$1; shift

	ASYNC_CALLBACKS[$worker]="$*"

	if (( ! ASYNC_USE_ZLE_HANDLER )); then
		trap '_async_notify_trap' WINCH
	fi
}

#
# Unregister the callback for a specific worker.
#
# usage:
# 	async_unregister_callback <worker_name>
#
async_unregister_callback() {
	typeset -gA ASYNC_CALLBACKS

	unset "ASYNC_CALLBACKS[$1]"
}

#
# Flush all current jobs running on a worker. This will terminate any and all running processes under the worker, use
# with caution.
#
# usage:
# 	async_flush_jobs <worker_name>
#
async_flush_jobs() {
	setopt localoptions noshwordsplit

	local worker=$1; shift

	# Check if the worker exists
	zpty -t $worker &>/dev/null || return 1

	# Send kill command to worker
	async_job $worker "_killjobs"

	# Clear all output buffers
	local junk
	if zpty -r -t $worker junk '*'; then
		(( ASYNC_DEBUG )) && print -n "async_flush_jobs $worker: ${(V)junk}"
		while zpty -r -t $worker junk '*'; do
			(( ASYNC_DEBUG )) && print -n "${(V)junk}"
		done
		(( ASYNC_DEBUG )) && print
	fi
}

#
# Start a new async worker with optional parameters, a worker can be told to only run unique tasks and to notify a
# process when tasks are complete.
#
# usage:
# 	async_start_worker <worker_name> [-u] [-n] [-p <pid>]
#
# opts:
# 	-u unique (only unique job names can run)
# 	-n notify through SIGWINCH signal
# 	-p pid to notify (defaults to current pid)
#
async_start_worker() {
	setopt localoptions noshwordsplit

	local worker=$1; shift
	zpty -t $worker &>/dev/null && return

	typeset -gA ASYNC_PTYS
	typeset -h REPLY
	typeset has_xtrace=0

	# Make sure async worker is started without xtrace
	# (the trace output interferes with the worker).
	[[ -o xtrace ]] && {
		has_xtrace=1
		unsetopt xtrace
	}

	zpty -b $worker _async_worker -p $$ $@ || {
		async_stop_worker $worker
		return 1
	}

	# Re-enable it if it was enabled, for debugging.
	(( has_xtrace )) && setopt xtrace

	if [[ $ZSH_VERSION < 5.0.8 ]]; then
		# For ZSH versions older than 5.0.8 we delay a bit to give
		# time for the worker to start before issuing commands,
		# otherwise it will not be ready to receive them.
		sleep 0.05
	fi

	if (( ASYNC_USE_ZLE_HANDLER )); then
		ASYNC_PTYS[$REPLY]=$worker
		zle -F $REPLY _async_zle_watcher

		# If worker was called with -n, disable trap in favor of zle handler
		async_job $worker _unset_trap
	fi
}

#
# Stop one or multiple workers that are running, all unfetched and incomplete work will be lost.
#
# usage:
# 	async_stop_worker <worker_name_1> [<worker_name_2>]
#
async_stop_worker() {
	setopt localoptions noshwordsplit

	local ret=0
	for worker in $@; do
		# Find and unregister the zle handler for the worker
		for k v in ${(@kv)ASYNC_PTYS}; do
			if [[ $v == $worker ]]; then
				zle -F $k
				unset "ASYNC_PTYS[$k]"
			fi
		done
		async_unregister_callback $worker
		zpty -d $worker 2>/dev/null || ret=$?
	done

	return $ret
}

#
# Initialize the required modules for zsh-async. To be called before using the zsh-async library.
#
# usage:
# 	async_init
#
async_init() {
	(( ASYNC_INIT_DONE )) && return
	ASYNC_INIT_DONE=1

	zmodload zsh/zpty
	zmodload zsh/datetime

	# Check if zsh/zpty returns a file descriptor or not,
	# shell must also be interactive with zle enabled.
	ASYNC_USE_ZLE_HANDLER=0
	[[ -o interactive ]] && [[ -o zle ]] && {
		typeset -h REPLY
		zpty _async_test :
		(( REPLY )) && ASYNC_USE_ZLE_HANDLER=1
		zpty -d _async_test
	}
}

async() {
	async_init
}

async "$@"
