#!/usr/bin/env bash

# Fails when any child process launched with the --gdunit-e2e flags is still
# running, on Linux and Windows. Run after the test suites; CI runs this with
# always() so a wedged child is reported even when a suite already failed.

set -uo pipefail

process_snapshot() {
	if [ "${RUNNER_OS:-}" = "Windows" ]; then
		powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
			'$self = $PID; Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $self -and $_.CommandLine } | ForEach-Object { "{0} {1}" -f $_.ProcessId, $_.CommandLine }'
	else
		ps -eo pid=,args=
	fi
}

# The scan lives in a function so the case's `)` is parsed outside the
# command substitution (macOS bash 3.2 ends the substitution there).
scan_survivors() {
	process_snapshot | while read -r pid command; do
		if [ "$pid" = "$$" ] || [ "$pid" = "${BASHPID:-$$}" ]; then
			continue
		fi
		case "$command" in
			*--gdunit-e2e*) printf '%s %s\n' "$pid" "$command" ;;
		esac
	done
}

survivors="$(scan_survivors)"

if [ -n "$survivors" ]; then
	echo "Found surviving --gdunit-e2e child process(es):" >&2
	echo "$survivors" >&2
	exit 1
fi

echo "No surviving --gdunit-e2e child processes."
