#!/usr/bin/env bash

# Builds a single git tree seeded with mainline u-boot plus the vendor forks Armbian's
# families build from, and exports it as a plain .tar of its .git directory. The armbian/build
# framework pulls that tar via ORAS and hangs `git worktree`s off it, so a cold build never has
# to clone u-boot -- and, for the Rockchip families, never has to pull Radxa's vendor history
# from a repo that is not CDN-fronted.
#
# Unlike the kernel (see work_kernel_tree.sh) there is no shallow variant: the whole u-boot
# tree is small enough that a single complete artifact serves every consumer.

set -e

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "::group::Prepare basics"

BASE_WORK_DIR="${BASE_WORK_DIR:-"/tmp/workdir"}"
WORKDIR="${BASE_WORK_DIR}/u-boot"
UBOOT_GIT_TREE="${WORKDIR}/worktree"
OUTPUT_DIR_ORAS="${WORKDIR}/output_oras"
OUTPUT_TARBALL="${OUTPUT_DIR_ORAS}/u-boot-complete.git.tar"
mkdir -p "${WORKDIR}" "${UBOOT_GIT_TREE}" "${OUTPUT_DIR_ORAS}"

# Mainline u-boot. Everything else is a fork of this, so it is fetched first and its tags are
# authoritative. github.com is used rather than source.denx.de because it is the mirror the
# build framework's own default (MAINLINE_UBOOT_SOURCE) points at.
MAINLINE_UBOOT_URL="${MAINLINE_UBOOT_URL:-"https://github.com/u-boot/u-boot.git"}"

# Vendor forks to seed alongside mainline, as "local_prefix | remote URL | branch glob".
# Their branches land under refs/heads/<local_prefix>/<branch>, so they can never collide with
# mainline's refs, and their tags are NOT fetched at all (see the --no-tags below).
#
# Adding an entry grows the single artifact that every Armbian user downloads. Keep the bar
# high: a fork earns a line here only if a supported family builds from it, and the glob should
# match only the branches config/sources/ actually references.
#   radxa next-dev*: next-dev-v2024.10 (rk35xx, rockchip-rk3588), next-dev-v2024.03
#                    (mekotronics vendor hook), next-dev-buildroot (rockchip-rv1106).
declare -ag EXTRA_TREES=(
	"radxa | https://github.com/radxa/u-boot.git | next-dev*"
)

# Refuse to publish an artifact that has silently ballooned; see the note on EXTRA_TREES above.
MAX_TARBALL_MIB="${MAX_TARBALL_MIB:-2048}"

if [[ ! -d "${UBOOT_GIT_TREE}/.git" ]]; then
	display_alert "Initting git tree" "${UBOOT_GIT_TREE}"
	git init --initial-branch="armbian_unused_initial_branch" "${UBOOT_GIT_TREE}"
else
	display_alert "Git tree already initted" "${UBOOT_GIT_TREE}"
fi

cd "${UBOOT_GIT_TREE}" || exit 2
git config gc.auto 0 # no surprise gc in the middle of the script; we repack explicitly at the end

echo "::endgroup::"

# 1st stage: mainline u-boot -- 'master' plus every tag.
#
# The explicit refspec overrides the remote's configured "+refs/heads/*:refs/remotes/mainline/*",
# so master lands directly in refs/heads and no refs/remotes/* is ever created. "--tags" adds
# refs/tags/*:refs/tags/* on top: nearly every Armbian board pins BOOTBRANCH to a "tag:vYYYY.MM",
# so shipping the tags is what makes those builds a cache hit instead of a fetch.
echo "::group::Fetching mainline u-boot"
display_alert "Fetching mainline u-boot" "${MAINLINE_UBOOT_URL}"
git remote add mainline "${MAINLINE_UBOOT_URL}" 2> /dev/null || git remote set-url mainline "${MAINLINE_UBOOT_URL}"
run_with_retries git fetch --progress --verbose --tags mainline "+refs/heads/master:refs/heads/master"
echo "::endgroup::"

# 2nd stage: the vendor forks.
#
# The branch glob is resolved with ls-remote first, rather than being handed straight to git as a
# wildcard refspec, for three reasons: a glob that goes stale fails loudly here instead of
# silently shipping nothing, the exact branch list ends up in the log, and it gives us somewhere
# to catch a directory/file ref conflict before git does with a much less obvious error.
#
# "--no-tags" is the tag-collision defence. Git auto-follows tags that point at downloaded
# objects, so without it a fork would drag in its copies of upstream's tag names (radxa's tree
# alone shares 322 tag names with mainline) and could shadow mainline's. Fork tags are not
# needed: nothing in config/sources/ references one.
for entry in "${EXTRA_TREES[@]}"; do
	IFS='|' read -r prefix url glob <<< "${entry}"
	prefix="$(trimmed "${prefix}")"
	url="$(trimmed "${url}")"
	glob="$(trimmed "${glob}")"

	echo "::group::Fetching extra tree ${prefix}"

	# This is config a human edits; complain about a malformed line rather than producing a
	# subtly wrong tree. The prefix becomes a ref path component, so it must be a legal one.
	[[ "${prefix}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || {
		display_alert "Invalid prefix in EXTRA_TREES entry" "'${entry}'" "err"
		exit 1
	}
	[[ -n "${url}" && -n "${glob}" ]] || {
		display_alert "Missing url or glob in EXTRA_TREES entry" "'${entry}'" "err"
		exit 1
	}

	git remote add "${prefix}" "${url}" 2> /dev/null || git remote set-url "${prefix}" "${url}"

	declare -a branches=() refspecs=()
	ls_remote_out="${WORKDIR}/ls-remote-${prefix}.txt"
	run_with_retries_capture "${ls_remote_out}" git ls-remote --heads "${url}" "refs/heads/${glob}"
	mapfile -t branches < <(awk '{print $2}' "${ls_remote_out}" | sed 's|^refs/heads/||' | sort)

	if [[ ${#branches[@]} -eq 0 ]]; then
		display_alert "No branches matched '${glob}' at ${url}" "stale EXTRA_TREES entry?" "err"
		exit 1
	fi

	# refs/heads/foo and refs/heads/foo/bar cannot both exist; git would fail the fetch with a
	# "cannot lock ref" deep in its output. Say so plainly instead.
	for one in "${branches[@]}"; do
		for other in "${branches[@]}"; do
			if [[ "${one}" != "${other}" && "${other}" == "${one}/"* ]]; then
				display_alert "Directory/file ref conflict in ${prefix}" "'${one}' vs '${other}'" "err"
				exit 1
			fi
		done
	done

	display_alert "Extra tree ${prefix}: ${#branches[@]} branches" "${branches[*]}"
	for one in "${branches[@]}"; do
		refspecs+=("+refs/heads/${one}:refs/heads/${prefix}/${one}")
	done

	run_with_retries git fetch --progress --verbose --no-tags "${prefix}" "${refspecs[@]}"
	echo "::endgroup::"
done

# 3rd stage: strip everything the consumer must not inherit, then collapse to one packfile.
echo "::group::Post-processing the tree"
cd "${UBOOT_GIT_TREE}" || exit 2

# The consumer fetches from explicit URLs and never by remote name, so remotes are dead weight
# that would only confuse anyone poking at the extracted tree.
for one_remote in $(git remote); do
	display_alert "Removing remote" "${one_remote}"
	git remote rm "${one_remote}"
done

rm -rf "${UBOOT_GIT_TREE}/.git/hooks"
rm -f "${UBOOT_GIT_TREE}/.git/FETCH_HEAD" "${UBOOT_GIT_TREE}/.git/ORIG_HEAD"

# gc.auto=0 was for this script's benefit only. Leaving it in the shipped tree would disable
# auto-repacking forever on the consumer, whose copy keeps growing as builds fetch into it.
git config --unset gc.auto

# The forced refspecs above wrote reflogs, and those pin objects that repack -d would otherwise
# be free to drop. Expire them first or the repack achieves much less than it looks like it does.
git reflog expire --expire=now --all

# Unlike work_kernel_tree.sh, this tree is built from two *network* fetches into one repo, which
# leaves two packfiles that each carry the shared u-boot history. Without this repack the
# artifact is roughly twice the size it needs to be. The window/depth are git's own
# "gc --aggressive" values; a few minutes here is cheap for an artifact downloaded daily.
display_alert "Repacking" "single packfile, this takes a while"
git repack -a -d --window=250 --depth=50
git pack-refs --all --prune

# Cosmetic: the consumer only ever asks for the 'master' branch by name, but leaving HEAD
# pointing at the throwaway init branch is just confusing to anyone who extracts the tar.
git symbolic-ref HEAD refs/heads/master

echo -n "all branches: " && (git branch -a | cat | xargs echo -n || true) && echo ""
echo -n "tag count: " && (git tag -l | wc -l || true)
git count-objects -vH
du -hsc "${UBOOT_GIT_TREE}/.git"
echo "::endgroup::"

# 4th stage: export. Members must be ".git/..." -- the consumer extracts with -C into the bare
# tree directory and then asserts that "${tree}/.git" exists.
echo "::group::Exporting tarball"
cd "${UBOOT_GIT_TREE}" || exit 2
display_alert "Exporting .tar" "${OUTPUT_TARBALL}"
tar cf "${OUTPUT_TARBALL}" .git
ls -lah "${OUTPUT_TARBALL}"

declare -i tarball_mib
tarball_mib="$(du -m "${OUTPUT_TARBALL}" | awk '{print $1}')"
display_alert "Tarball size" "${tarball_mib} MiB (ceiling ${MAX_TARBALL_MIB} MiB)"
if [[ ${tarball_mib} -gt ${MAX_TARBALL_MIB} ]]; then
	display_alert "Tarball is over the size ceiling" "${tarball_mib} MiB > ${MAX_TARBALL_MIB} MiB" "err"
	display_alert "Trim EXTRA_TREES, or raise MAX_TARBALL_MIB if the growth is intended" "" "err"
	exit 1
fi
echo "::endgroup::"
