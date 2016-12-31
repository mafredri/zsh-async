#!/usr/bin/env zsh
#
# zsh-async test runner.
# Checks for test files named *_test.zsh or *_test.sh and runs all functions
# named test_*.
#
# usage:
#   ./test.zsh
#
emulate -L zsh

zmodload zsh/datetime

source **/*_test.(zsh|sh)

# run_test runs the test function and reports it's status.
run_test() {
	local ret

	float start=$EPOCHREALTIME duration
	out="$(
		# Initialize async.
		source ./async.zsh
		async_init

		# Run the test.
		$t 2>&1
	)"
	ret=$?
	duration=$(( EPOCHREALTIME - start ))

	# Print everything at once to avoid garbled text.
	print "$(
		print -- "=== RUN   $t"
		if (( ret == 0 )); then
			print -- "--- PASS: $t $(printf "(%.2fs)" $duration)"
		else
			print -- "--- FAIL: $t"
			print -- "\tstatus: $ret"
			print -- "\toutput: $out"
		fi
	)"

	print -p $ret

	return $ret
}

# Open coproc for receiving messages from run_test().
coproc cat

# Find all functions named test_*.
tests=(${(okM)functions:#test_*})
num_tests=${#tests}

# Run all the tests asynchronously.
for t in $tests; do
	run_test $t &
done

fail=0
codes=()
(( num_tests > 0 )) && while read -p code; do
	codes+=($code)

	# Non-zero exit code from test, that's a fail!
	(( code != 0 )) && fail=1

	# Break if we've received an exit code from all tests.
	(( ${#codes} == num_tests )) && break
done

# Close the message coproc.
coproc :

# Wait for all child processes to exit.
wait

# Just one failure, ruins everything 😢.
(( fail )) && {
	print "FAIL"
	exit 1
}

# Green lights all the way, baby!
print "PASS"
exit 0
