#!/usr/bin/env zsh
#
# zsh-async test runner.
# Checks for test files named *_test.zsh or *_test.sh and runs all functions
# named test_*.
#
emulate -L zsh

zmodload zsh/datetime
zmodload zsh/parameter
zmodload zsh/zutil

TEST_GLOB=.
TEST_VERBOSE=0
TEST_CODE_SKIP=101
TEST_CODE_ERROR=100

show_help() {
	print "usage: ./test.zsh [-v] [search glob]"
}

parse_opts() {
	local -a verbose help
	zparseopts -E -D \
		v=verbose -verbose=verbose \
		h=help -help=help \
		\?=help

	(( $+help[1] )) && show_help && exit 0

	if (( $#@ > 1 )); then
		print -- "unknown arguments: $@"
		show_help
		exit 1
	fi

	[[ -n $1 ]] && TEST_GLOB=$1/
	TEST_VERBOSE=$+verbose[1]
}

# t_log is for printing log output, visible in verbose (-v) mode.
t_log() {
	print -u 3 -- $'\t'"${funcfiletrace[1]}: $@"
}

# t_skip is for skipping a test.
t_skip() {
	t_log $@
	exit $TEST_CODE_SKIP
}

typeset -g -a err_lines
# t_error logs the error and fails the test without aborting.
t_error() {
	# Store the function line that produced the error in
	# err_lines, used to figure out if an error happened.
	err_lines+=(${${(s.:.)functrace[1]}[2]})
	t_log $@
}

# t_fatal logs the error and immediately fails the test.
t_fatal() {
	t_log $@
	exit $TEST_CODE_ERROR
}

# run_test runs the test function and reports it's status.
run_test() {
	local num=$1 t=$2 code

	# Manage stdout / stderr.
	exec 3>&1
	if (( ! TEST_VERBOSE )); then
		exec 4>/dev/null
	else
		exec 4>&1
	fi
	# Run the test.
	$t 1>&4 2>&3
	code=$?
	(( ${#err_lines} )) && return $TEST_CODE_ERROR
	return $code
}

# run_test_module runs all the tests from a test module (asynchronously).
run_test_module() {
	local module=$1 num_tests=0
	local -a tests
	float start duration

	source $module

	# Find all functions named test_* (sorted), excluding test_main.
	tests=(${(R)${(okM)functions:#test_*}:#test_main})
	num_tests=${#tests}

	# Run test_main.
	if [[ -n $functions[test_main] ]]; then
		test_main
	fi

	start=$EPOCHREALTIME

	# Open coproc for test results.
	coproc cat

	# Run all the tests asynchronously.
	local i=0
	for t in $tests; do
		(( i++ ))
		{
			local code out
			float start=$EPOCHREALTIME duration
			out="$(run_test $i $t)"
			code=$?
			duration=$(( EPOCHREALTIME - start ))
			print -r -p $i $code $duration "${(q)out}"$'\0'
		} &
	done

	local code
	local -A codes times outputs
	# Parse all test results from coproc.
	(( i > 0 )) && while read -r -d $'\0' -A -p line; do
		code=$line[1]; shift line
		codes+=($code $line[1])
		times+=($code $line[2])
		shift 2 line
		outputs+=($code "${(Q)line}")

		# Check if we've received all results.
		(( ${#codes} == i )) && break
	done

	coproc exit

	duration=$(( EPOCHREALTIME - start ))

	local test state output show failed=0
	for ti in ${(onk)codes}; do
		state=PASS
		test=$tests[$ti]
		code=$codes[$ti]
		output=$outputs[$ti]
		show=$TEST_VERBOSE

		if (( code == TEST_CODE_ERROR )); then
			state=FAIL
			show=1
			(( failed++ ))
		elif (( code == TEST_CODE_SKIP )); then
			state=SKIP
		fi

		if (( !show )); then
			continue
		fi
		print "=== RUN   $test"
		print -n -- "--- $state: $test"
		printf " (%.2fs)\n" $times[$ti]
		[[ -n $output ]] && print $output
	done

	if (( failed > 0 )); then
		print "FAIL"
		printf "FAIL\t$module\t%.3fs\n" $duration
		return 1
	fi

	if (( TEST_VERBOSE )); then
		print "PASS"
	fi
	printf "ok\t$module\t%.3fs\n" $duration
}

# Parse command arguments.
parse_opts $@

# Execute tests modules.
failed=0
for tf in ${~TEST_GLOB}/*_test.(zsh|sh); do
	run_test_module $tf &
	wait $!
	(( $? )) && failed=1
done

exit $failed
