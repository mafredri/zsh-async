#!/usr/bin/env zsh

. ./async.zsh
async_init

simple_echo() {
	print hi
}

git_status() {
	git status --porcelain
}

error_echo() {
	print "I will print some errors, yay!"
	1234
	4321
	exit 100
}

null_echo() {
	print Hello$'\0' with$'\0' nulls!
	print "Did we catch them all?"$'\0'
	print $'\0'"What about the errors?"$'\0' 1>&2
}

simple_result() {
	print
	print -l -- $1: $3
}

result() {
	print
	print -l -r -- "Compelted job: '$1'" "Return code: $2" "Duration: $4 seconds" "Stdout: '${3//$'\n'/\n}'" "Stderr: '${5//$'\n'/\n}'"
}

integer JOBS
jobs_job() {
	JOBS+=1
	async_job jobs_worker $@
}

jobs_callback() {
	JOBS+=-1
	result $@
}

# Test a simple print...
async_start_worker async
async_job async simple_echo
async_job async git status --porcelain
sleep 0.2
async_process_results async simple_result

# Test uniqueness
async_start_worker async2 -u
# Only the first one will run!
# The second cannot run due to unique constraint.
async_job async2 git_status
async_job async2 git_status
sleep 0.2
# Only results for first git status
async_process_results async2 result

async_start_worker jobs_worker -n
async_register_callback jobs_worker jobs_callback
jobs_job error_echo
jobs_job null_echo

print
print "Waiting for $JOBS jobs to finnish via callbacks..."
while (( JOBS > 0 )); do
	sleep 0.001
done
print
print "Jobs done!"

# Cleanup
async_stop_worker async async2 || print "ERROR: Could not clean up workers"
async_stop_worker nonexistent && print "ERROR: Sucess cleaning up nonexistent worker"
