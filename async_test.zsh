#!/usr/bin/env zsh

test__async_job_print_hi() {
	coproc cat
	print -p t  # Insert token into coproc.

	local IFS=$'\0'  # Split on NULLs.
	local out
	out=($(_async_job print hi))

	coproc exit

	[[ $out[1] = print ]] || t_error "command name should be print, got" $out[1]
	[[ $out[2] = 0 ]] || t_error "want exit code 0, got" $out[2]
	[[ $out[3] = hi ]] || t_error "want output: hi, got" $out[3]
}

test__async_job_stderr() {
	coproc cat
	print -p t  # Insert token into coproc.

	local IFS=$'\0'  # Split on NULLs.
	local out
	out=($(_async_job 'print hi 1>&2'))

	coproc exit

	[[ $out[2] = 0 ]] || t_error "want status 0, got" $out[2]
	[[ -z $out[3] ]] || t_error "want empty output, got" $out[3]
	[[ $out[5] = hi ]] || t_error "want stderr: hi, got" $out[5]
}

test__async_job_wait_for_token() {
	float start duration
	coproc cat

	_async_job print hi >/dev/null &
	job=$!
	start=$EPOCHREALTIME
	{
		sleep 0.1
		print -p t
	} &

	wait $job

	coproc exit

	duration=$(( EPOCHREALTIME - start ))
	# Fail if the execution time was faster than 0.1 seconds.
	(( duration >= 0.1 )) || t_error "execution was too fast, want >= 0.1, got" $duration
}

test__async_job_multiple_commands() {
	coproc cat
	print -p t

	local IFS=$'\0'  # Split on NULLs.
	local out
	out=($(_async_job 'print -n hi; for i in "1 2" 3 4; do print -n $i; done'))

	coproc exit

	# $out[1] here will be the entire string passed to _async_job()
	# ('print -n hi...') since proper command parsing is done by
	# the async worker.
	[[ $out[3] = "hi1 234" ]] || t_error "want output hi1 234, got " $out[3]
}

test_async_start_stop_worker() {
	local out

	async_start_worker test
	out=$(zpty -L)
	[[ $out =~ "test _async_worker" ]] || t_error "want zpty worker running, got ${(q-)out}"

	async_stop_worker test || t_error "stop worker: want exit code 0, got $?"
	out=$(zpty -L)
	[[ -z $out ]] || t_error "want no zpty worker running, got ${(q-)out}"

	async_stop_worker nonexistent && t_error "stop non-existent worker: want exit code 1, got $?"
}

test_async_job_multiple_commands_in_string() {
	local -a result
	cb() { result=("$@") }

	async_start_worker test
	async_job test 'print -n "hi  123 "; print -n bye'
	while ! async_process_results test cb; do :; done
	async_stop_worker test

	[[ $result[1] = print ]] || t_error "want command name: print, got" $result[1]
	[[ $result[3] = "hi  123 bye" ]] || t_error 'want output: "hi  123 bye", got' ${(q-)result[3]}
}

test_async_job_git_status() {
	local -a result
	cb() { result=("$@") }

	async_start_worker test
	async_job test git status --porcelain
	while ! async_process_results test cb; do :; done
	async_stop_worker test

	[[ $result[1] = git ]] || t_error "want command name: git, got" $result[1]
	[[ $result[2] = 0 ]] || t_error "want exit code: 0, got" $result[2]

	want=$(git status --porcelain)
	got=$result[3]
	[[ $got = $want ]] || t_error "want ${(q-)want}, got ${(q-)got}"
}

test_async_job_multiple_arguments_and_spaces() {
	local -a result
	cb() { result=("$@") }

	async_start_worker test
	async_job test print "hello   world"
	while ! async_process_results test cb; do :; done
	async_stop_worker test

	[[ $result[1] = print ]] || t_error "want command name: print, got" $result[1]
	[[ $result[2] = 0 ]] || t_error "want exit code: 0, got" $result[2]

	[[ $result[3] = "hello   world" ]] || {
		t_error "want output: \"hello   world\", got" ${(q-)result[3]}
	}
}

test_async_job_unique_worker() {
	local -a result
	cb() {
		# Add to result so we can detect if it was called multiple times.
		result+=("$@")
	}
	helper() {
		sleep 0.1; print $1
	}

	# Start a unique (job) worker.
	async_start_worker test -u

	# Launch two jobs with the same name, the first one should be
	# allowed to complete whereas the second one is never run.
	async_job test helper one
	async_job test helper two

	while ! async_process_results test cb; do :; done

	# If both jobs were running but only one was complete,
	# async_process_results() could've returned true for
	# the first job, wait a little extra to make sure the
	# other didn't run.
	sleep 0.1
	async_process_results test cb

	async_stop_worker test

	# Ensure that cb was only called once with correc output.
	[[ ${#result} = 5 ]] || t_error "result: want 5 elements, got" ${#result}
	[[ $result[3] = one ]] || t_error "output: want 'one', got" ${(q-)result[3]}
}

test_async_job_error_and_nonzero_exit() {
	local -a r
	cb() { r+=("$@") }
	error() {
		print "Errors!"
		12345
		54321
		print "Done!"
		exit 99
	}

	async_start_worker test
	async_job test error

	while ! async_process_results test cb; do :; done

	[[ $r[1] = error ]] || t_error "want 'error', got ${(q-)r[1]}"
	[[ $r[2] = 99 ]] || t_error "want exit code 99, got $r[2]"

	want=$'Errors!\nDone!'
	[[ $r[3] = $want ]] || t_error "want ${(q-)want}, got ${(q-)r[3]}"

	want=$'.*command not found: 12345\n.*command not found: 54321'
	[[ $r[5] =~ $want ]] || t_error "want ${(q-)want}, got ${(q-)r[5]}"
}

test_async_worker_notify_sigwinch() {
	local -a result
	cb() { result=("$@") }

	ASYNC_USE_ZLE_HANDLER=0

	async_start_worker test -n
	async_register_callback test cb

	async_job test 'sleep 0.1; print hi'

	while (( ! $#result )); do sleep 0.01; done

	async_stop_worker test

	[[ $result[3] = hi ]] || t_error "expected output: hi, got" $result[3]
}

test_async_job_removes_nulls() {
	local -a r
	cb() { r=("$@") }
	null_echo() {
		print Hello$'\0' with$'\0' nulls!
		print "Did we catch them all?"$'\0'
		print $'\0'"What about the errors?"$'\0' 1>&2
	}

	async_start_worker test
	async_job test null_echo

	while ! async_process_results test cb; do :; done

	async_stop_worker test

	local want
	want=$'Hello with nulls!\nDid we catch them all?'
	[[ $r[3] = $want ]] || t_error stdout: want ${(q-)want}, got ${(q-)r[3]}
	want='What about the errors?'
	[[ $r[5] = $want ]] || t_error stderr: want ${(q-)want}, got ${(q-)r[5]}
}

test_async_flush_jobs() {
	local -a r
	cb() { r=("$@") }
	many_procs() {
		{ sleep 0.15 && print -n 1 } &
		{ sleep 0.2 && print -n 2 } &
		wait
	}

	async_start_worker test
	async_job test many_procs

	sleep 0.1

	async_flush_jobs test

	sleep 0.2
	async_process_results test cb

	async_stop_worker test

	[[ $r[3] = "" ]] || t_error "stdout: want '', got ${(q-)r[3]}"
}

zpty_init() {
	zmodload zsh/zpty

	export PS1='<PROMPT>'
	zpty zsh 'zsh -f +Z'
	zpty -r zsh zpty_init1 "*<PROMPT>*" || {
		t_log "initial prompt missing"
		return 1
	}

	tmp=$(mktemp -t async_test_zpty_init.XXXXXX)
	print -lr - "$@" > $tmp
	zpty -w zsh ". '$tmp'"
	zpty -r -m zsh zpty_init2 "*<PROMPT>*" || {
		t_log "prompt missing"
		rm $tmp
		return 1
	}
	rm $tmp
}

zpty_run() {
	zpty -w zsh "$*"
	zpty -r -m zsh zpty_run "*<PROMPT>*" || {
		t_log "prompt missing after ${(q-)*}"
		return 1
	}
}

zpty_deinit() {
	zpty -d zsh
}

test_zle_watcher() {
	if [[ $ZSH_VERSION < 5.2 ]]; then
		t_skip "zpty does not return a file descriptor on zsh <5.2"
	fi

	zpty_init '
		emulate -R zsh
		setopt zle
		stty 38400 columns 80 rows 24 tabs -icanon -iexten
		TERM=vt100

		. "'$PWD'/async.zsh"
		async_init
		print_result_cb() { print ${(q-)@} }
	' || {
		zpty_deinit
		t_fatal "failed to init zpty"
	}

	zpty_run async_start_worker test || {
		zpty_deinit
		t_fatal "could not start async worker"
	}

	zpty_run async_register_callback test print_result_cb || {
		zpty_deinit
		t_fatal "could not register callback"
	}

	zpty -w zsh "zle -F"
	zpty -r -m zsh result "*_async_zle_watcher*" || {
		zpty_deinit
		t_fatal "want _async_zle_watcher to be registered as zle watcher, got output ${(q-)result}"
	}

	zpty_run async_job test 'print hello world' || {
		zpty_deinit
		t_fatal "could not send async_job command"
	}

	zpty -r -m zsh result "*print 0 'hello world'*" || {
		zpty_deinit
		t_fatal "want \"print 0 'hello world'\", got output ${(q-)result}"
	}

	zpty_deinit
}

test_main() {
	# Load zsh-async before running each test.
	zmodload zsh/datetime
	. ./async.zsh
	async_init
}
