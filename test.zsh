#!/usr/bin/env zsh
#
# zsh-async test runner.
# Checks for test files named *_test.zsh or *_test.sh and runs all functions
# named test_*.
#
emulate -L zsh

trap '
	trap '' HUP
	kill -HUP -$$
	trap '' EXIT
	exit 1
' INT EXIT TERM

zmodload zsh/datetime
zmodload zsh/parameter
zmodload zsh/zutil
zmodload zsh/zpty

TEST_GLOB=.
TEST_RUN=
TEST_VERBOSE=0
TEST_TRACE=1
TEST_CODE_ERROR=100
TEST_CODE_SKIP=101
TEST_CODE_TIMEOUT=102

show_help() {
	print "usage: ./test.zsh [-v] [-x] [-run pattern] [search pattern]"
}

parse_opts() {
	local -a verbose trace help run

	local out
	zparseopts -E -D \
		v=verbose verbose=verbose -verbose=verbose \
		x=trace trace=trace -trace=trace \
		h=help -help=help \
		\?=help \
		run:=run -run:=run

	(( $? )) || (( $+help[1] )) && show_help && exit 0

	if (( $#@ > 1 )); then
		print -- "unknown arguments: $@"
		show_help
		exit 1
	fi

	[[ -n $1 ]] && TEST_GLOB=$1/
	TEST_VERBOSE=$+verbose[1]
	TEST_TRACE=$+trace[1]
	(( $+run[2] )) && TEST_RUN=$run[2]
}

# t_log is for printing log output, visible in verbose (-v) mode.
t_log() {
	print "\t${funcfiletrace[1]}: $@"
}

# t_skip is for skipping a test.
t_skip() {
	print "\t${funcfiletrace[1]}: $@"
	exit $TEST_CODE_SKIP
}

# t_error logs the error and fails the test without aborting.
t_error() {
	# Store the function line that produced the error in
	# __test_err_lines, used to figure out if an error happened.
	__test_err_lines+=(${${(s.:.)functrace[1]}[2]})
	print "\t${funcfiletrace[1]}: $@"
}

# t_fatal logs the error and immediately fails the test.
t_fatal() {
	print "\t${funcfiletrace[1]}: $@"
	exit $TEST_CODE_ERROR
}

# t_timeout sets a timeout for the test (10 seconds by default).
t_timeout() {
	local timeout=${1:-10}
	(( __test_timeout_pid )) && kill -KILL $__test_timeout_pid
	{
		sleep $timeout
		print "\t${funcfiletrace[1]}: timed out after ${timeout}s"
		kill -ALRM $$
	} &
	__test_timeout_pid=$!
}

# run_test_worker launches a worker and waits for a test (runs in zpty).
run_test_worker() {
	emulate -L zsh

	integer __test_timeout_pid=0 __test_exit=0
	typeset -g -a __test_err_lines

	__test_cleanup() {
		trap '' TERM    # Catch SIGTERM
		kill -TERM -$$  # Terminate process group.
		trap - TERM     # Reset trap.
	}
	__test_end() {
		print -n $'\0'$__test_exit$'\0'
		printf "%.2fs"$'\0' $__test_time
		print -n DONE$'\0'
		(( TEST_TRACE )) && unsetopt xtrace  # Do not log sleep...

		# Keep test worker running until all output has been read.
		while :; do sleep 1; done
	}

	# Set TRAPALRM for catching timeouts.
	TRAPALRM() {
		__test_cleanup

		__test_exit=TEST_CODE_TIMEOUT
		__test_time=$(( EPOCHREALTIME - __test_start ))
		__test_end
	}

	# Wait for the function name for the test.
	read __test_name

	(( TEST_TRACE )) && {
		# Redirect stderr (trace) to log file (to keep test stdout clean).
		exec 2>/tmp/ztest-${__test_name}.log
		setopt xtrace
	}

	# Set default timeout for test (10 seconds).
	t_timeout

	# Start counting time for test execution.
	float __test_start=$EPOCHREALTIME __test_time=0

	# Run test.
	$__test_name
	__test_exit=$?
	__test_time=$(( EPOCHREALTIME - __test_start ))

	# Preform cleanup tasks.
	__test_cleanup

	# Did we encounter any errors?
	(( $#__test_err_lines > 0 )) && __test_exit=$TEST_CODE_ERROR

	__test_end
}

# run_test_module runs all the tests from a test module (asynchronously).
run_test_module() {
	local module=$1
	local -a tests
	float start module_time

	# Load the test module.
	source $module

	# Find all functions named test_* (sorted), excluding test_main.
	tests=(${(R)${(okM)functions:#test_*}:#test_main})
	[[ -n $TEST_RUN ]] && tests=(${(M)tests:#*$TEST_RUN*})
	num_tests=${#tests}

	# Run test_main.
	if [[ -n $functions[test_main] ]]; then
		test_main
	fi

	# Launch all zpty test runners.
	for t in $tests; do
		(( TEST_TRACE )) && unsetopt xtrace
		zpty -b $t run_test_worker
		(( TEST_TRACE )) && setopt xtrace
	done

	if [[ $ZSH_VERSION < 5.0.8 ]]; then
		# Give the zpty worker time to boot-up on pre-5.0.8 versions of zsh.
		sleep 0.05
	fi

	# Track execution time for test module.
	start=$EPOCHREALTIME

	# Send the test function to the runner, initiating the test.
	for t in $tests; do
		zpty -w $t $t
	done

	typeset -A results
	typeset -a _tests
	_tests=($tests)
	# Copy the output buffer until all tests have completed.
	while (( $#_tests )); do
		for t in $_tests; do
			line="$results[$t]"

			# Read all available output from zpty.
			while zpty -rt $t l; do
				line+="$l"
			done

			# Check if we received all output from test,
			# if true, we stop processing it.
			if [[ $line[$#line-5,$#line] = $'\0'DONE$'\0' ]]; then
				_tests=("${(@)_tests:#$t}")
			fi

			results[$t]="$line"
		done

		# Add a tiny delay between iterations, we provide 3-decimal
		# accuracy for test-suite, so this should be OK.
		sleep 0.0001
	done

	module_time=$(( EPOCHREALTIME - start ))

	# Clean up zpty test runners.
	zpty -d $tests

	typeset -a test_result
	typeset state time out
	integer show code failed=0
	IFS=$'\0'
	# Parse test results and pretty-print them.
	for t in $tests; do
		test_result=("${(@)=results[$t]}")

		state=PASS
		show=$TEST_VERBOSE
		code=$test_result[2]
		time=$test_result[3]
		out=$test_result[1]

		if (( code == TEST_CODE_ERROR )); then
			state=FAIL
			show=1
			(( failed++ ))
		elif (( code == TEST_CODE_TIMEOUT )); then
			state=FAIL
			show=1
			(( failed++ ))
		elif (( code == TEST_CODE_SKIP )); then
			state=SKIP
		fi

		if (( !show )); then
			continue
		fi
		print "=== RUN   $t"
		print -- "--- $state: $t ($time)"
		[[ -n $out ]] && print -n $out
	done

	# Print test module status.
	if (( failed > 0 )); then
		print "FAIL"
		printf "FAIL\t$module\t%.3fs\n" $module_time
		return 1
	fi

	if (( TEST_VERBOSE )); then
		print "PASS"
	fi
	printf "ok\t$module\t%.3fs\n" $module_time
}

# Parse command arguments.
parse_opts $@

(( TEST_TRACE )) && setopt xtrace

# Execute tests modules.
failed=0
for tf in ${~TEST_GLOB}/*_test.(zsh|sh); do
	run_test_module $tf &
	wait $!
	(( $? )) && failed=1
done

exit $failed
