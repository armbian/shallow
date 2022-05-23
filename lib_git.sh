function display_alert() {
	echo "--> $*"
}

function run_host_command_logged() {
	echo "==> $*"
	"$@"
}


function git_fetch_from_bundle_file() {
	local bundle_file="${1}" remote_name="${2}" shallow_file="${3}"
	git bundle verify "${bundle_file}"               # Make sure bundle is valid.
	git remote add "${remote_name}" "${bundle_file}" # Add the remote pointing to the cold bundle file
	if [[ -f "${shallow_file}" ]]; then
		display_alert "Bundle is shallow" "${shallow_file}" "git"
		cp -p "${shallow_file}" ".git/shallow"
	fi
	git fetch --progress --verbose --tags "${remote_name}" # Fetch it! (including tags!)
	display_alert "Bundle fetch '${remote_name}' completed"
}

function download_git_bundle_from_http() {
	local bundle_file="${1}" bundle_url="${2}"
	if [[ ! -f "${git_cold_bundle_cache_file}" ]]; then                          # Download the bundle file if it does not exist.
		display_alert "Downloading Git cold bundle via HTTP" "${bundle_url}" "info" # This gonna take a while. And waste bandwidth
		run_host_command_logged wget --continue --progress=dot:giga --output-document="${bundle_file}" "${bundle_url}"
	else
		display_alert "Cold bundle file exists, using it" "${bundle_file}" "git"
	fi
}
