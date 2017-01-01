#!/usr/bin/env zsh

test__async_job_print_hi() {
	coproc cat
	print -p t  # Insert token into coproc.

	local IFS=$'\0'  # Split on NULLs.
	local out
	out=($(_async_job print hi))

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

	duration=$(( EPOCHREALTIME - start ))
	# Fail if the execution time was faster than 0.1 seconds.
	(( duration > 0.1 )) || t_error "execution was too fast, want > 0.1, got" $duration
}

test__async_job_multiple_commands() {
	coproc cat
	print -p t

	local IFS=$'\0'  # Split on NULLs.
	local out
	out=($(_async_job 'print -n hi; for i in "1 2" 3 4; do print -n $i; done'))

	# $out[1] here will be the entire string passed to _async_job()
	# ('print -n hi...') since proper command parsing is done by
	# the async worker.
	[[ $out[3] = "hi1 234" ]] || t_error "want output hi1 234, got " $out[3]
}

test_async_job_multiple_commands_in_string() {
	local -a result
	cb() { result=("$@") }

	async_start_worker test
	async_job test 'print -n "hi  123 "; print -n bye'
	while ! async_process_results test cb; do
		sleep 0.1
	done

	[[ $result[1] = print ]] || t_error "want command name: print, got" $result[1]
	[[ $result[3] = "hi  123 bye" ]] || t_error 'want output: "hi  123 bye", got' ${(qqq)result[3]}
}

test_async_job_git_status() {
	local -a result
	cb() { result=("$@") }

	async_start_worker test
	async_job test git status --porcelain
	while ! async_process_results test cb; do
		sleep 0.1
	done

	[[ $result[1] = git ]] || t_error "want command name: git, got" $result[1]
	[[ $result[2] = 0 ]] || t_error "want exit code: 0, got" $result[2]

	want=$(git status --porcelain)
	got=$result[3]
	[[ $got = $want ]] || t_error "want ${(qqq)want}, got ${(qqq)got}"
}

test_async_job_multiple_arguments_and_spaces() {
	local -a result
	cb() { result=("$@") }

	async_start_worker test
	async_job test print "hello   world"
	while ! async_process_results test cb; do
		sleep 0.1
	done

	[[ $result[1] = print ]] || t_error "want command name: print, got" $result[1]
	[[ $result[2] = 0 ]] || t_error "want exit code: 0, got" $result[2]

	[[ $result[3] = "hello   world" ]] || {
		t_error "want output: \"hello   world\", got" ${(qqq)result[3]}
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

	while ! async_process_results test cb; do
		sleep 0.1
	done

	# If both jobs were running but only one was complete,
	# async_process_results() could've returned true for
	# the first job, wait a little extra to make sure the
	# other didn't run.
	sleep 0.1
	async_process_results test cb

	# Ensure that cb was only called once with correc output.
	[[ ${#result} = 5 ]] || t_error "result: want 5 elements, got" ${#result}
	[[ $result[3] = one ]] || t_error "output: want \"one\", got" ${(qqq)result[3]}
}

test_main() {
	# Load zsh-async before running each test.
	zmodload zsh/datetime
	source async.zsh
	async_init
}
