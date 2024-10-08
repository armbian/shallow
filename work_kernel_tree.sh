#!/usr/bin/env bash

set -e

function display_alert() {
	echo "--> $*"
}
echo "::group::Read kernel.org versions"
# Read the current versions of kernel from kernel.org JSON releases. Again, thanks, kernel.org.
curl --silent "https://www.kernel.org/releases.json" > /tmp/kernel-releases.json
echo "Kernel releases versions from JSON:"
cat /tmp/kernel-releases.json | jq -r ".releases[].version"

declare -ag WANTED_KERNEL_VERSIONS_KERNEL_ORG
mapfile -t WANTED_KERNEL_VERSIONS_KERNEL_ORG < <(cat /tmp/kernel-releases.json | jq -r ".releases[].version" | grep -v -e "^next\-" | sed -e 's|-rc|.-rc|' | cut -d "." -f 1,2)

# Include some extra ones that Armbian uses in legacies etc
declare -ag WANTED_KERNEL_VERSIONS=("${WANTED_KERNEL_VERSIONS_KERNEL_ORG[@]}" "4.9" "4.4")

# Show the array
display_alert "Wanted kernel versions:" "${WANTED_KERNEL_VERSIONS[@]}"
echo "::endgroup::"

echo "::group::Prepare basics"
ONLINE="${ONLINE:-"yes"}"
EXPORT_SHALLOW_PER_VERSION="yes"
EXPORT_COMPLETE="yes" # note: The complete .tar is bigger than 2gb, and that does not fit into GH Releases 2gb limit for any single file. Use ORAS and ghcr.io.
BASE_WORK_DIR="${BASE_WORK_DIR:-"/Volumes/LinuxDev/shallow_git_tree_work"}"
WORKDIR="${BASE_WORK_DIR}/kernel"
SHALLOWED_TREES_DIR="${WORKDIR}/shallow_trees"
COMPLETE_TREES_DIR="${WORKDIR}/complete_trees"
OUTPUT_DIR_ORAS="${WORKDIR}/output_oras"
KERNEL_GIT_TREE="${WORKDIR}/worktree"
KERNEL_TORVALDS_BUNDLE_DIR="${WORKDIR}/bundle-torvalds"
ALL_VERSIONS_FILE="${OUTPUT_DIR_ORAS}/shallow_versions.txt"
mkdir -p "${BASE_WORK_DIR}" "${WORKDIR}" "${SHALLOWED_TREES_DIR}" "${COMPLETE_TREES_DIR}" "${KERNEL_GIT_TREE}" "${KERNEL_TORVALDS_BUNDLE_DIR}" "${OUTPUT_DIR_ORAS}"

GIT_TORVALDS_BUNDLE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/clone.bundle" # Thanks, kernel.org!
GIT_TORVALDS_BUNDLE_ID="$(echo -n "${GIT_TORVALDS_BUNDLE_URL}" | md5sum | awk '{print $1}')"              # md5 of the URL.
GIT_TORVALDS_BUNDLE_FILE="${KERNEL_TORVALDS_BUNDLE_DIR}/${GIT_TORVALDS_BUNDLE_ID}.gitbundle"              # final filename of bundle
GIT_TORVALDS_BUNDLE_REMOTE_NAME="torvalds-gitbundle"                                                      # name of the remote that will point to bundle
GIT_TORVALDS_LIVE_GIT_URL="git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"              # Torvalds live tree git:// URL
GIT_TORVALDS_LIVE_REMOTE_NAME="torvalds-live"                                                             # name of the remote that will point to live Torvalds tree
GIT_STABLE_LIVE_GIT_URL="git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"           # Stable live tree git:// URL
GIT_STABLE_LIVE_REMOTE_NAME="stable-live"                                                                 # name of the remote that will point to live stable tree

# 1st stage Global:
# Init an empty git repo
if [[ ! -d "${KERNEL_GIT_TREE}/.git" ]]; then
	display_alert "Initting git tree"
	git init --initial-branch="armbian_unused_initial_branch" "${KERNEL_GIT_TREE}"
else
	display_alert "Git tree already initted"
fi

echo "::endgroup::"
echo "::group::Fetching Torvalds bundle"

## From now on, everything is done inside the git worktree...
cd "${KERNEL_GIT_TREE}" || exit 2

if ! git config "remote.${GIT_TORVALDS_BUNDLE_REMOTE_NAME}.url"; then
	# Grab torvald's gitbundle via http from kernel.org
	if [[ ! -f "${GIT_TORVALDS_BUNDLE_FILE}" ]]; then # Download the bundle file if it does not exist.
		display_alert "Downloading Git cold bundle via HTTP" "${GIT_TORVALDS_BUNDLE_URL}"
		wget --continue --progress=dot:giga --output-document="${GIT_TORVALDS_BUNDLE_FILE}" "${GIT_TORVALDS_BUNDLE_URL}"
	else
		display_alert "Cold bundle file exists, using it" "${GIT_TORVALDS_BUNDLE_FILE}" "git"
	fi

	# Fetch from Torvalds bundle (very slow) into 'torvalds-gitbundle' branch
	display_alert "Fetching from cold git bundle, wait" "${GIT_TORVALDS_BUNDLE_ID}"
	git bundle verify "${GIT_TORVALDS_BUNDLE_FILE}"                                   # Make sure bundle is valid.
	git remote add "${GIT_TORVALDS_BUNDLE_REMOTE_NAME}" "${GIT_TORVALDS_BUNDLE_FILE}" # Add the remote pointing to the cold bundle file
	git fetch --progress --verbose "${GIT_TORVALDS_BUNDLE_REMOTE_NAME}"               # Fetch it!
else
	display_alert "Torvalds bundle already fetched..."
fi

# At this stage, we've all blobs, but no tags!

echo "::endgroup::"

echo "::group::Fetching Torvalds live"
# 2nd stage Global:
# Add torvalds live git as remote 'torvalds-live'
if ! git config "remote.${GIT_TORVALDS_LIVE_REMOTE_NAME}.url"; then
	display_alert "Adding torvalds live remote" "${GIT_TORVALDS_LIVE_REMOTE_NAME}"
	git remote add "${GIT_TORVALDS_LIVE_REMOTE_NAME}" "${GIT_TORVALDS_LIVE_GIT_URL}"
else
	display_alert "Torvalds live remote already exists..."
fi

# Fetch from it (to update), also bring in the tags. Around a 60mb download, quite fast.
if [[ "${ONLINE}" == "yes" ]]; then
	display_alert "Fetching from torvalds live" "${GIT_TORVALDS_LIVE_REMOTE_NAME}"
	git fetch --progress --verbose --tags "${GIT_TORVALDS_LIVE_REMOTE_NAME}" master # Fetch it! (including tags!)
	# create a local branch from the fetched
	display_alert "Creating local branch 'torvalds-master' from torvalds live" "${GIT_TORVALDS_LIVE_REMOTE_NAME}"
	git branch --force "torvalds-master" FETCH_HEAD
fi
echo "::endgroup::"

echo "::group::Adding stable remote"
# Now, add the stable remote. Do NOT fetch from it, it's huge and has a lot more than we need.
if ! git config "remote.${GIT_STABLE_LIVE_REMOTE_NAME}.url"; then
	display_alert "Adding stable live remote" "${GIT_STABLE_LIVE_REMOTE_NAME}"
	git remote add "${GIT_STABLE_LIVE_REMOTE_NAME}" "${GIT_STABLE_LIVE_GIT_URL}"
else
	display_alert "Stable live remote already exists..."
fi
echo "::endgroup::"

# 3rd stage: For each version, eg: 5.17
# - Fetch from stable git source (not bundle) into `stable-5.17` branch
#   - include tags
#   - if this fails (eg: an unreleased kernel at that moment, tolerate and go ahead, torvalds should have -rc1)
WANTED_KERNEL_VERSIONS_COUNT=${#WANTED_KERNEL_VERSIONS[@]}
display_alert "Wanted kernel versions: ${WANTED_KERNEL_VERSIONS_COUNT}"

for KERNEL_VERSION in "${WANTED_KERNEL_VERSIONS[@]}"; do
	echo "::group::Fetching stable remote for ${KERNEL_VERSION}"
	display_alert "Fetching stable kernel version: ${KERNEL_VERSION}"

	KERNEL_VERSION_LOCAL_BRANCH_NAME="linux-${KERNEL_VERSION}.y"
	KERNEL_VERSION_REMOTE_BRANCH_NAME="linux-${KERNEL_VERSION}.y"

	# Fetch the branch from the stable live into the local branch. Since I don't specify "--tags", it will only fetch the tags for the branch. Those DON'T include the -rc tags which came from torvalds live
	if [[ "${ONLINE}" == "yes" ]]; then
		declare -i STABLE_EXISTS=0
		git fetch --progress --verbose "${GIT_STABLE_LIVE_REMOTE_NAME}" "${KERNEL_VERSION_REMOTE_BRANCH_NAME}:${KERNEL_VERSION_LOCAL_BRANCH_NAME}" && STABLE_EXISTS=1
		if [[ ${STABLE_EXISTS} -eq 0 ]]; then
			display_alert "Stable branch does not exist, copying torvalds-master to" "${KERNEL_VERSION_REMOTE_BRANCH_NAME}"
			git branch --force "${KERNEL_VERSION_LOCAL_BRANCH_NAME}" "torvalds-master"
		fi
	fi
	echo "::endgroup::"

done

# 4th stage: For each version, eg 5.17
# - Find the earliest tag with 5.17 in it
#    - find the _date_ for such a tag
# - Export a shallow bundle via the date for that version;
#   - include the shallow marker file (.git/shallow)
if [[ "${EXPORT_SHALLOW_PER_VERSION}" == "yes" ]]; then
	echo "Writing file with all versions: ${ALL_VERSIONS_FILE}"
	echo "${WANTED_KERNEL_VERSIONS[@]}" > "${ALL_VERSIONS_FILE}"

	for KERNEL_VERSION in "${WANTED_KERNEL_VERSIONS[@]}"; do
		echo "::group::Exporting shallow for ${KERNEL_VERSION}"

		cd "${KERNEL_GIT_TREE}" || exit 2

		KERNEL_VERSION_LOCAL_BRANCH_NAME="linux-${KERNEL_VERSION}.y"
		display_alert "Finding shallow point for version: ${KERNEL_VERSION}" "on local branch" "${KERNEL_VERSION_LOCAL_BRANCH_NAME}"

		# shit happens upstream too, so filter out "-dontuse" tags.
		KERNEL_VERSION_FIRST_RC_TAG_NAME="$(git tag -l | grep "^v$(echo -n "${KERNEL_VERSION}" | sed -e 's/\./\\\./')-rc" | grep -v "\-dontuse" | sort -n | head -1)"
		display_alert "Found first RC for version:" "${KERNEL_VERSION}" "${KERNEL_VERSION_FIRST_RC_TAG_NAME}"

		# Now translate that tag into a date, which what we're gonna use to shallow the bundle.
		# Attention: date has timezone part.
		KERNEL_VERSION_SHALLOW_AT_DATE="$(git tag --list --format="%(creatordate)" "${KERNEL_VERSION_FIRST_RC_TAG_NAME}")"
		display_alert "Date for first RC tag:" "${KERNEL_VERSION}" "${KERNEL_VERSION_FIRST_RC_TAG_NAME}" "'${KERNEL_VERSION_SHALLOW_AT_DATE}'"

		# Clone from the worktree into a new directory, shallowing in the process. This is the only way to make it consistently shallow without jumping through hoops.
		KERNEL_VERSION_SHALLOWED_WORKDIR="${SHALLOWED_TREES_DIR}/shallow-${KERNEL_VERSION}-${KERNEL_VERSION_FIRST_RC_TAG_NAME}"

		if [[ ! -d "${KERNEL_VERSION_SHALLOWED_WORKDIR}" ]]; then
			display_alert "Making shallow tree" "${KERNEL_VERSION_SHALLOWED_WORKDIR}"
			# --progress --verbose -- too much output for github actions
			git clone --no-checkout \
				--single-branch --branch="${KERNEL_VERSION_LOCAL_BRANCH_NAME}" \
				--tags --shallow-since="${KERNEL_VERSION_SHALLOW_AT_DATE}" \
				"file://${KERNEL_GIT_TREE}" "${KERNEL_VERSION_SHALLOWED_WORKDIR}"
		else
			display_alert "Shallow tree already exists" "${KERNEL_VERSION_SHALLOWED_WORKDIR}"
		fi

		OUTPUT_BUNDLE_FILE_NAME_TARBALL="${OUTPUT_DIR_ORAS}/linux-shallow-${KERNEL_VERSION}.git.tar"

		cd "${KERNEL_VERSION_SHALLOWED_WORKDIR}"

		# Create a 'master' branch, which is the default branch name for git. Copy the shallowed branch.
		git branch --force master "${KERNEL_VERSION_LOCAL_BRANCH_NAME}"

		# Remove the origin remote, otherwise it would be exported due to "--all" below.
		if git config "remote.origin.url"; then
			git remote rm origin
		fi

		# remove hooks, if dir exists
		if [[ -d "${KERNEL_VERSION_SHALLOWED_WORKDIR}/.git/hooks" ]]; then
			rm -rf "${KERNEL_VERSION_SHALLOWED_WORKDIR}/.git/hooks"
		fi

		# list all tags in the shallow tree
		echo -n "all tags ${KERNEL_VERSION}: "
		git -C "${KERNEL_VERSION_SHALLOWED_WORKDIR}" tag -l | cat | xargs echo -n || true
		echo ""

		# list all branches in the shallow tree
		echo -n "all branches ${KERNEL_VERSION}: "
		git -C "${KERNEL_VERSION_SHALLOWED_WORKDIR}" branch -a | cat | xargs echo -n || true
		echo ""

		# export a .tar of .git. This is gonna be uploaded into ghcr.io via ORAS.
		tar cf "${OUTPUT_BUNDLE_FILE_NAME_TARBALL}" .git

		# List the outputs with sizes
		ls -laht "${OUTPUT_DIR_ORAS}/linux-shallow-${KERNEL_VERSION}".* || true

		echo "::endgroup::"
	done
fi

# 5th stage: export complete tree for the active versions, not shallow.
# Will be used for the separate-git+worktree version.
if [[ "${EXPORT_COMPLETE}" == "yes" ]]; then
	echo "::group::Exporting complete tree for multiple worktree seeding"

	KERNEL_VERSION_COMPLETE_WORKDIR="${COMPLETE_TREES_DIR}/complete1"
	display_alert "Making complete tree" "${KERNEL_VERSION_COMPLETE_WORKDIR}"

	if [[ ! -d "${KERNEL_VERSION_COMPLETE_WORKDIR}" ]]; then
		echo "Empty init..."
		git init --initial-branch="armbian_unused_first_branch" "${KERNEL_VERSION_COMPLETE_WORKDIR}"
	fi

	declare -a WANTED_BRANCHES=()
	for KERNEL_VERSION in "${WANTED_KERNEL_VERSIONS[@]}"; do
		KERNEL_VERSION_LOCAL_BRANCH_NAME="linux-${KERNEL_VERSION}.y"
		WANTED_BRANCHES+=("${KERNEL_VERSION_LOCAL_BRANCH_NAME}:${KERNEL_VERSION_LOCAL_BRANCH_NAME}")
	done
	# Include a 'master' reference from torvalds-master; this way the produced export has the expected 'master' branch
	WANTED_BRANCHES+=("torvalds-master:master")

	# Do a single fetch against all the branches...
	cd "${KERNEL_VERSION_COMPLETE_WORKDIR}" || exit 3
	echo "adding branches ${WANTED_BRANCHES[*]}..."
	# --progress --verbose -- too much output for github actions
	git fetch "file://${KERNEL_GIT_TREE}" "${WANTED_BRANCHES[@]}"

	# list all tags in the complete tree
	echo -n "all tags (complete): "
	git -C "${KERNEL_VERSION_COMPLETE_WORKDIR}" tag -l | cat | xargs echo -n || true
	echo ""

	# list all branches in the complete tree
	echo -n "all branches (complete):"
	git -C "${KERNEL_VERSION_COMPLETE_WORKDIR}" branch -a | cat | xargs echo -n || true
	echo ""

	# remove hooks, if dir exists
	if [[ -d "${KERNEL_VERSION_COMPLETE_WORKDIR}/.git/hooks" ]]; then
		rm -rf "${KERNEL_VERSION_COMPLETE_WORKDIR}/.git/hooks"
	fi

	# show du human total size of the complete tree
	echo -n "total size:"
	du -hsc "${KERNEL_VERSION_COMPLETE_WORKDIR}"

	# export the complete tree
	OUTPUT_BUNDLE_FILE_NAME_COMPLETE="${OUTPUT_DIR_ORAS}/linux-complete.git.tar"
	echo "Exporting .tar ${OUTPUT_BUNDLE_FILE_NAME_COMPLETE} "
	tar cf "${OUTPUT_BUNDLE_FILE_NAME_COMPLETE}" .git
	ls -lah "${OUTPUT_BUNDLE_FILE_NAME_COMPLETE}"

	echo "::endgroup::"
fi

# In GHA, cache the full git work tree, if it fits in GHA cache;
# If cache hit, skip 1st stage, but _always_ execute stages 2-4 (to update the cache)
