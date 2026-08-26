#!/usr/bin/env bash

# Shared helpers for the tree-preparation scripts (work_kernel_tree.sh, work_uboot_tree.sh).
# Sourced, never executed directly.

function display_alert() {
	echo "--> $*"
}

# Retry a (remote) command up to RETRY_MAX_ATTEMPTS times, with an increasing delay
# between attempts (RETRY_BASE_DELAY, doubling each time). Used to wrap network/git
# operations against upstream git mirrors, which fail intermittently. Each attempt is also
# bounded by a timeout that starts at RETRY_TIMEOUT and doubles every attempt (some
# operations hang forever instead of failing, and slow local work like "Resolving deltas"
# can legitimately need more time on later retries). On timeout the command is killed
# (SIGTERM, then SIGKILL after a grace period) and counts as a failure. Returns the last
# exit code.
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-5}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-10}"
RETRY_TIMEOUT="${RETRY_TIMEOUT:-600}" # seconds; 10 minutes for the first attempt, doubling thereafter
function run_with_retries() {
	local -i attempt=1
	local -i delay="${RETRY_BASE_DELAY}"
	local -i timeout_s="${RETRY_TIMEOUT}"
	local -i rc=0
	while true; do
		display_alert "Attempt ${attempt}/${RETRY_MAX_ATTEMPTS} (timeout ${timeout_s}s):" "$*"
		timeout --kill-after=30s "${timeout_s}" "$@" && return 0
		rc=$?
		if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
			display_alert "Command timed out after ${timeout_s}s (rc=${rc}):" "$*" "wrn"
		fi
		if [[ ${attempt} -ge ${RETRY_MAX_ATTEMPTS} ]]; then
			display_alert "Command failed after ${RETRY_MAX_ATTEMPTS} attempts (rc=${rc}):" "$*" "err"
			return ${rc}
		fi
		display_alert "Command failed (rc=${rc}), retrying in ${delay}s:" "$*" "wrn"
		sleep "${delay}"
		attempt+=1
		delay=$((delay * 2))
		timeout_s=$((timeout_s * 2))
	done
}

# Like run_with_retries(), but sends the command's stdout to <outfile> instead of letting it
# through. run_with_retries() execs the command with stdout inherited, so it cannot be used
# inside a "$(...)": its own attempt/retry messages would land in the captured output. And
# 'timeout' cannot run a bash function, hence the 'bash -c' trampoline.
# <outfile> <command...>
function run_with_retries_capture() {
	local outfile="${1}" && shift
	# shellcheck disable=SC2016 # single quotes are the point: $1/$@ must expand in the inner bash
	run_with_retries bash -c 'out="$1"; shift; "$@" > "${out}"' _ "${outfile}" "$@"
}

# Echo the argument with leading and trailing whitespace removed.
function trimmed() {
	local s="${1}"
	s="${s#"${s%%[![:space:]]*}"}"
	echo -n "${s%"${s##*[![:space:]]}"}"
}
