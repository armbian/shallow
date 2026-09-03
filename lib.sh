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

# Exit code from git_fetch_mirrored() when every mirror agrees the wanted ref does not exist.
GIT_FETCH_NO_SUCH_REF=3

# Fetch, rotating over a list of mirrors as attempts fail:
#   git_fetch_mirrored <url> [<url>...] -- <git-fetch args and refspecs...>
# The URL is passed to git first, the caller's arguments after it (git permutes options past
# the repo argument just fine).
#
# Mirrors are given in preference order and each attempt moves to the next one, wrapping
# around when there are more attempts than mirrors -- so the retries of run_with_retries()
# double as mirror failover, and a single-mirror list simply degrades to plain retries.
# Attempts are never fewer than the number of mirrors: every mirror gets at least one go.
#
# Fetches fail in two ways that want opposite handling, so they are told apart here:
#   - "couldn't find remote ref": retrying the same mirror is pointless, but a mirror that
#     lags upstream (kernel.googlesource.com can be days behind on a fresh -rc tag) is not
#     evidence that the ref does not exist, so the next mirror is tried immediately, with no
#     backoff. Only when every mirror has said the same is the ref really missing, and that
#     returns GIT_FETCH_NO_SUCH_REF right away instead of burning the whole retry budget.
#     Callers use it to tell "upstream has not branched this version yet" from "the network
#     is having a bad day", which are very different things to react to.
#   - anything else (refused, hung up, timed out): the usual growing backoff and timeout, on
#     the next mirror.
function git_fetch_mirrored() {
	local -a mirrors=() fetch_args=()
	while [[ $# -gt 0 ]]; do
		[[ "${1}" == "--" ]] && {
			shift
			break
		}
		mirrors+=("${1}")
		shift
	done
	fetch_args=("$@")
	if [[ ${#mirrors[@]} -eq 0 || ${#fetch_args[@]} -eq 0 ]]; then
		display_alert "git_fetch_mirrored: usage:" "<url> [<url>...] -- <git-fetch args...>" "err"
		return 1
	fi

	local -i mirror_count=${#mirrors[@]}
	local -i max_attempts=${RETRY_MAX_ATTEMPTS}
	[[ ${mirror_count} -gt ${max_attempts} ]] && max_attempts=${mirror_count}
	local -i attempt=1 delay="${RETRY_BASE_DELAY}" timeout_s="${RETRY_TIMEOUT}" rc=0 missing_streak=0
	local url outfile
	outfile="$(mktemp "${TMPDIR:-/tmp}/git-fetch-mirrored.XXXXXX")"

	while true; do
		url="${mirrors[$(((attempt - 1) % mirror_count))]}"
		display_alert "Fetch attempt ${attempt}/${max_attempts} (timeout ${timeout_s}s) from ${url}:" "${fetch_args[*]}"
		# tee, so the output is still live in the log while also being available to grep below.
		# The pipeline's own status is tee's, hence PIPESTATUS for git's; and being 0 it also
		# keeps a failed fetch from tripping the caller's "set -e" before we can react to it.
		timeout --kill-after=30s "${timeout_s}" git fetch "${url}" "${fetch_args[@]}" 2>&1 | tee "${outfile}"
		rc="${PIPESTATUS[0]}"
		if [[ ${rc} -eq 0 ]]; then
			rm -f "${outfile}"
			return 0
		fi

		if grep -q "couldn't find remote ref" "${outfile}"; then
			missing_streak+=1
			if [[ ${missing_streak} -ge ${mirror_count} ]]; then
				display_alert "Ref not found on any of the ${mirror_count} mirror(s):" "${fetch_args[*]}" "wrn"
				rm -f "${outfile}"
				return ${GIT_FETCH_NO_SUCH_REF}
			fi
			display_alert "Ref not found on ${url}, trying the next mirror:" "${fetch_args[*]}" "wrn"
			attempt+=1
			continue # no backoff, and no timeout escalation: the mirror answered, it just lags
		fi
		missing_streak=0

		if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
			display_alert "Fetch timed out after ${timeout_s}s (rc=${rc}) on ${url}:" "${fetch_args[*]}" "wrn"
		fi
		if [[ ${attempt} -ge ${max_attempts} ]]; then
			display_alert "Fetch failed after ${max_attempts} attempts (rc=${rc}):" "${fetch_args[*]}" "err"
			rm -f "${outfile}"
			return ${rc}
		fi
		display_alert "Fetch failed (rc=${rc}), retrying in ${delay}s on the next mirror:" "${fetch_args[*]}" "wrn"
		sleep "${delay}"
		attempt+=1
		delay=$((delay * 2))
		timeout_s=$((timeout_s * 2))
	done
}

# Echo the argument with leading and trailing whitespace removed.
function trimmed() {
	local s="${1}"
	s="${s#"${s%%[![:space:]]*}"}"
	echo -n "${s%"${s##*[![:space:]]}"}"
}
