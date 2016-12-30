#!/usr/bin/env zsh

zmodload zsh/datetime

test__async_job_print_hi() {
	coproc cat
	print -p t

	local IFS=$'\0'
	local out=($(_async_job print hi))
	print $out
	[[ $out[1] == print ]] && [[ $out[2] == 0 ]] && [[ $out[3] = hi ]]
}

test__async_job_wait_for_token() {
	coproc cat

	_async_job print hi &
	job=$!
	start=$EPOCHREALTIME
	{
		sleep 0.1
		print -p t
	} &

	wait $job

	# Fail if the execution time was faster than 0.1 seconds.
	return $(( (EPOCHREALTIME - start) <= 0.1 ))
}

test__async_job_multiple_commands() {
	coproc cat
	print -p t

	local IFS=$'\0'
	local out=($(_async_job 'print -n hi; for i in "1 2" 3 4; do print -n $i; done'))
	print $out

	[[ $out[3] = "hi1 234" ]]
}

test_async_job_process_callback() {
	local -a result
	cb() { result=($@) }

	async_start_worker test
	async_job test 'print -n "hi  123 "; print -n bye'
	while ! (( ${#result} )); do
		async_process_results test cb
	done

	print $result

	[[ $result[1] = print ]] && [[ $result[3] = "hi  123 bye" ]]
}
