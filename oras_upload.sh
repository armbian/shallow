#!/usr/bin/env bash

set -e

function display_alert() {
	echo "--> $*"
}

function run_tool_oras() {
	# Default target
	if [[ -z "${DIR_ORAS}" ]]; then
		display_alert "DIR_ORAS is not set, using default"
		if [[ -n "${SRC}" ]]; then
			DIR_ORAS="${SRC}/cache/tools/oras"
		else
			display_alert "Missing DIR_ORAS, or SRC fallback" "DIR_ORAS: ${DIR_ORAS}; SRC: ${SRC}" "wrn"
			return 1
		fi
	else
		display_alert "DIR_ORAS is set to ${DIR_ORAS}"
	fi

	mkdir -p "${DIR_ORAS}"

	# Default version
	ORAS_VERSION=${ORAS_VERSION:-0.16.0} # https://github.com/oras-project/oras/releases

	MACHINE="${BASH_VERSINFO[5]}"
	display_alert "Running ORAS" "ORAS version ${ORAS_VERSION}" "debug"
	MACHINE="${BASH_VERSINFO[5]}"
	case "$MACHINE" in
		*darwin*) ORAS_OS="darwin" ;;
		*linux*) ORAS_OS="linux" ;;
		*)
			display_alert "unknown os: $MACHINE"
			exit 3
			;;
	esac

	case "$MACHINE" in
		*aarch64*) ORAS_ARCH="arm64" ;;
		*x86_64*) ORAS_ARCH="amd64" ;;
		*)
			display_alert "unknown arch: $MACHINE"
			exit 2
			;;
	esac

	ORAS_FN="oras_${ORAS_VERSION}_${ORAS_OS}_${ORAS_ARCH}"
	ORAS_FN_TARXZ="${ORAS_FN}.tar.gz"
	DOWN_URL="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${ORAS_FN_TARXZ}"
	ORAS_BIN="${DIR_ORAS}/${ORAS_FN}"

	if [[ ! -f "${ORAS_BIN}" ]]; then
		display_alert "Cache miss, downloading..."
		display_alert "MACHINE: ${MACHINE}"
		display_alert "Down URL: ${DOWN_URL}"
		display_alert "ORAS_BIN: ${ORAS_BIN}"

		wget -O "${ORAS_BIN}.tar.gz" "${DOWN_URL}"
		tar -xf "${ORAS_BIN}.tar.gz" -C "${DIR_ORAS}" "oras"
		rm -rf "${ORAS_BIN}.tar.gz"
		mv -v "${DIR_ORAS}/oras" "${ORAS_BIN}"
		chmod +x "${ORAS_BIN}"
	fi
	ACTUAL_VERSION="$("${ORAS_BIN}" version | grep "^Version" | xargs echo -n)"
	display_alert "Running ORAS ${ACTUAL_VERSION}"

	# If arguments passed, run oras with it
	if [[ -n "$*" ]]; then
		display_alert "Running ORAS" "$*" "debug"
		"${ORAS_BIN}" "$@"
	fi
}

function oras_push_artifact_file() {
	declare image_full_oci="${1}" # Something like "ghcr.io/rpardini/armbian-git-shallow/kernel-git:latest"
	declare upload_file="${2}"    # Absolute path to the file to upload including the path and name
	declare upload_file_base_path upload_file_name
	display_alert "Pushing ${upload_file} to ${image_full_oci}" "ORAS" "info"

	# make sure file exists
	if [[ ! -f "${upload_file}" ]]; then
		display_alert "File not found: ${upload_file}" "ORAS upload" "err"
		return 1
	fi

	# split the path and the filename
	upload_file_base_path="$(dirname "${upload_file}")"
	upload_file_name="$(basename "${upload_file}")"
	display_alert "upload_file_base_path: ${upload_file_base_path}" "ORAS upload" "debug"
	display_alert "upload_file_name: ${upload_file_name}" "ORAS upload" "debug"

	pushd "${upload_file_base_path}"
	run_tool_oras push --verbose "${image_full_oci}" "${upload_file_name}:application/vnd.unknown.layer.v1+tar"
}

DIR_ORAS=/tmp/oras_git_shallow
#oras_push_artifact_file "ghcr.io/rpardini/armbian-git-shallow/kernel-git:latest" "/Volumes/LinuxDev/shallow_git_tree_work/kernel/output/linux-complete.git.tar"
oras_push_artifact_file "${TARGET_OCI}" "${TARGET_FULL_FILE_PATH}"
echo "Done."