#!/usr/bin/env bash

set -e
set -x

# source the lib
. lib_git.sh

ONLINE="yes"

BASE_WORK_DIR="${BASE_WORK_DIR:-"/Volumes/LinuxDev/shallow_git_tree_work"}"
mkdir -p "${BASE_WORK_DIR}"

WORKDIR="${BASE_WORK_DIR}/kernel"
mkdir -p "${WORKDIR}"

SHALLOWED_TREES_DIR="${WORKDIR}/shallow_trees"
mkdir -p "${SHALLOWED_TREES_DIR}"

OUTPUT_DIR="${WORKDIR}/output"
mkdir -p "${OUTPUT_DIR}"

KERNEL_GIT_TREE="${WORKDIR}/worktree"
mkdir -p "${KERNEL_GIT_TREE}"

KERNEL_TORVALDS_BUNDLE_DIR="${WORKDIR}/bundle-torvalds"
mkdir -p "${KERNEL_TORVALDS_BUNDLE_DIR}"

GIT_TORVALDS_BUNDLE_URL="https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/clone.bundle"
GIT_TORVALDS_BUNDLE_ID="$(echo -n "${GIT_TORVALDS_BUNDLE_URL}" | md5sum | awk '{print $1}')" # md5 of the URL.
GIT_TORVALDS_BUNDLE_FILE="${KERNEL_TORVALDS_BUNDLE_DIR}/${GIT_TORVALDS_BUNDLE_ID}.gitbundle" # final filename of bundle
GIT_TORVALDS_BUNDLE_REMOTE_NAME="torvalds-gitbundle"                                         # name of the remote that will point to bundle

# TORVALDS LIVE info
GIT_TORVALDS_LIVE_GIT_URL="git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git"
GIT_TORVALDS_LIVE_REMOTE_NAME="torvalds-live"

GIT_STABLE_LIVE_GIT_URL="git://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git"
GIT_STABLE_LIVE_REMOTE_NAME="stable-live"

# Versions we're interested in, array
declare -ag WANTED_KERNEL_VERSIONS=("5.18" "5.17" "5.15" "5.12" "5.10")

# Minimal version

# Kernel versions: 5.18, 5.17, 5.15, 5.10, 4.19, 4.9, 4.4

# 1st stage Global:

# Init an empty git repo
# Fetch from Torvalds bundle (very slow) into 'torvalds-gitbundle' branch
# include tags?
if [[ ! -d "${KERNEL_GIT_TREE}/.git" ]]; then
	display_alert "Initting git tree"
	git init --initial-branch="armbian_unused_initial_branch" "${KERNEL_GIT_TREE}"
else
	display_alert "Git tree already initted"
fi

## From now on, everything is done inside the git worktree...
cd "${KERNEL_GIT_TREE}" || exit 2

if ! git config "remote.${GIT_TORVALDS_BUNDLE_REMOTE_NAME}.url"; then
	# Grab torvald's gitbundle via http from kernel.org
	download_git_bundle_from_http "${GIT_TORVALDS_BUNDLE_FILE}" "${GIT_TORVALDS_BUNDLE_URL}"
	display_alert "Fetching from cold git bundle, wait" "${GIT_TORVALDS_BUNDLE_ID}"
	git_fetch_from_bundle_file "${GIT_TORVALDS_BUNDLE_FILE}" "${GIT_TORVALDS_BUNDLE_REMOTE_NAME}"
else
	display_alert "Torvalds bundle already fetched..."
fi

# At this stage, we've all blobs, but no tags!

# 2nd stage Global:
# Add torvalds live git as remote 'torvalds-live'
if ! git config "remote.${GIT_TORVALDS_LIVE_REMOTE_NAME}.url"; then
	display_alert "Adding torvalds live remote" "${GIT_TORVALDS_LIVE_REMOTE_NAME}"
	git remote add "${GIT_TORVALDS_LIVE_REMOTE_NAME}" "${GIT_TORVALDS_LIVE_GIT_URL}"
else
	display_alert "Torvalds live remote already exists..."
fi

# Fetch from it (to update), also bring in the tags. Around a 60mb download, quite fast.
[[ "${ONLINE}" == "yes" ]] && git fetch --progress --verbose --tags "${GIT_TORVALDS_LIVE_REMOTE_NAME}" # Fetch it! (including tags!)

# Now, add the stable remote. Do NOT fetch from it, it's huge and has a lot more than we need.
if ! git config "remote.${GIT_STABLE_LIVE_REMOTE_NAME}.url"; then
	display_alert "Adding stable live remote" "${GIT_STABLE_LIVE_REMOTE_NAME}"
	git remote add "${GIT_STABLE_LIVE_REMOTE_NAME}" "${GIT_STABLE_LIVE_GIT_URL}"
else
	display_alert "Stable live remote already exists..."
fi

# 3rd stage: For each version, eg: 5.17
# - Fetch from stable git source (not bundle) into `stable-5.17` branch
#   - include tags?
#   - if this fails (eg: an unreleased kernel at that moment, tolerate and go ahead, torvalds should have -rc1)
WANTED_KERNEL_VERSIONS_COUNT=${#WANTED_KERNEL_VERSIONS[@]}
display_alert "Wanted kernel versions: ${WANTED_KERNEL_VERSIONS_COUNT}"

for KERNEL_VERSION in "${WANTED_KERNEL_VERSIONS[@]}"; do
	display_alert "Fetching stable kernel version: ${KERNEL_VERSION}"

	KERNEL_VERSION_LOCAL_BRANCH_NAME="linux-${KERNEL_VERSION}.y"
	KERNEL_VERSION_REMOTE_BRANCH_NAME="linux-${KERNEL_VERSION}.y"

	# Fetch the branch from the stable live into the local branch. Since I don't specify "--tags", it will only fetch the tags for the branch. Those DON'T include the -rc tags which came from torvalds live
	[[ "${ONLINE}" == "yes" ]] && git fetch --progress --verbose "${GIT_STABLE_LIVE_REMOTE_NAME}" "${KERNEL_VERSION_REMOTE_BRANCH_NAME}:${KERNEL_VERSION_LOCAL_BRANCH_NAME}"
done

# 4th stage: For each version, eg 5.17
# - Find the earliest tag with 5.17 in it, or 5.17-rc1 if all else fails;
#    - find the _date_ for such a tag
# - Export a shallow bundle via the date for that version;
#   - include the shallow marker file (eg: .git/shallow)
#   - lightweight tarball of those things, many -0 zstd
#   - publish the tarball as GH releases, always in "latest" release
for KERNEL_VERSION in "${WANTED_KERNEL_VERSIONS[@]}"; do
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
	#rm -rf "${KERNEL_VERSION_SHALLOWED_WORKDIR}"

	if [[ ! -d "${KERNEL_VERSION_SHALLOWED_WORKDIR}" ]]; then
		display_alert "Making shallow tree" "${KERNEL_VERSION_SHALLOWED_WORKDIR}"
		git clone --no-checkout --progress --verbose \
			--single-branch --branch="${KERNEL_VERSION_LOCAL_BRANCH_NAME}" \
			--tags --shallow-since="${KERNEL_VERSION_SHALLOW_AT_DATE}" \
			"file://${KERNEL_GIT_TREE}" "${KERNEL_VERSION_SHALLOWED_WORKDIR}"
	else
		display_alert "Shallow tree already exists" "${KERNEL_VERSION_SHALLOWED_WORKDIR}"
	fi

	OUTPUT_BUNDLE_DIR="${OUTPUT_DIR}" # /${KERNEL_VERSION}"
	mkdir -p "${OUTPUT_BUNDLE_DIR}"

	OUTPUT_BUNDLE_FILE_NAME_BUNDLE="${OUTPUT_BUNDLE_DIR}/linux-${KERNEL_VERSION}.gitbundle"
	OUTPUT_BUNDLE_FILE_NAME_SHALLOW="${OUTPUT_BUNDLE_DIR}/linux-${KERNEL_VERSION}.gitshallow"

	cd "${KERNEL_VERSION_SHALLOWED_WORKDIR}"

	# Remove the origin remote, otherwise it would be exported due to "--all" below.
	if git config "remote.origin.url"; then
		git remote rm origin
	fi

	# Now, export a bundle from the shallow tree. This is gonna be a shallow bundle, of course!
	git bundle create "${OUTPUT_BUNDLE_FILE_NAME_BUNDLE}" --all

	# export the shallow file, so it can be actually used.
	cp -pv ".git/shallow" "${OUTPUT_BUNDLE_FILE_NAME_SHALLOW}"

	# sanity check
	git bundle list-heads "${OUTPUT_BUNDLE_FILE_NAME_BUNDLE}"
done

# In GHA, cache the full git work tree, if it fits in GHA cache;
# If cache hit, skip 1st stage, but _always_ execute stages 2-4 (to update the cache)
