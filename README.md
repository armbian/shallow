<h2 align="center">
  <a href=#><img src="https://raw.githubusercontent.com/armbian/.github/master/profile/logosmall.png" alt="Armbian logo"></a>
  <br><br>
</h2>

# Armbian Shallow Git Trees

## Purpose of This Repository

This repository automates the daily preparation and publication of **shallow Linux kernel git bundles** and a **combined U-Boot git tree**, distributed as OCI artifacts via `ghcr.io`. These artifacts let Armbian CI and end-user builds start from pre-primed git trees instead of cloning multi-gigabyte histories from upstream on every run.

## Why

Full kernel trees are several gigabytes in size and take considerable time and resources to clone. While shallow clones reduce this overhead, fetching them directly still places significant load on the source servers.

To address this, `kernel.org` provides [pre-generated git bundles](https://git-scm.com/docs/git-bundle), which are simple archive files downloadable via CDN. These are the recommended method for CI usage according to [kernel.org best practices](https://www.kernel.org/best-way-to-do-linux-clones-for-your-ci.html).

This repository:

- Downloads the upstream `torvalds/linux` cold `clone.bundle` from kernel.org.
- Updates it from live git mirrors (kernel.org, GitHub, kernel.googlesource.com), with mirror failover and retry/backoff.
- For each wanted kernel version (all currently-listed versions from `kernel.org/releases.json`, plus legacy `4.9` and `4.4`), produces a shallow bundle anchored at the appropriate `-rc` tag.
- Ensures relevant version tags (including `-rc` tags from Torvalds' tree) are included.
- Also publishes a single **complete** kernel tree artifact, and a **combined U-Boot** tree artifact.
- Runs on a daily schedule via GitHub Actions, with a watchdog that reruns failed jobs.

> Optimized shallow bundles are ~300 MB — significantly smaller than full clones and much faster to work with.

## U-Boot trees

The same repository also prepares a **combined U-Boot git tree**, for the same reason and via the same mechanism — but with no shallow variant, since the whole tree is small enough that one complete artifact serves every consumer.

It is seeded with:

- **Mainline U-Boot** — `master` plus every tag. Nearly every Armbian board pins its `BOOTBRANCH` to a `tag:vYYYY.MM`, so shipping the tags is what makes those builds a cache hit rather than a fetch.
- **Vendor forks** listed in the `EXTRA_TREES` table in `work_uboot_tree.sh`, whose branches land under `refs/heads/<prefix>/`. Currently just Radxa's `next-dev*`, which the `rk35xx`, `rockchip-rk3588` and `rockchip-rv1106` families build from.

The tree is also the shared object store for every *other* U-Boot fork Armbian builds (TI, SolidRun, NXP, Xilinx, hardkernel, orangepi-xunlong, CoreELEC, …) — those are not seeded, but they fetch into a tree that already holds mainline's history, so their fetches stay small.

> The U-Boot artifact is ~390 MB, single-packfile.

## Published artifacts

All artifacts are pushed to GitHub Container Registry (`ghcr.io`) as OCI artifacts using [ORAS](https://oras.land/):

| Artifact | Image | Contents |
| --- | --- | --- |
| Per-version shallow kernel bundles | `ghcr.io/armbian/shallow/kernel-git-shallow-<version>:latest` | Shallow `.git.tar` for each wanted kernel version |
| Complete kernel tree | `ghcr.io/armbian/shallow/kernel-git:latest` | Full `linux-complete.git.tar` (too large for a GitHub Release's 2 GiB per-file limit) |
| Combined U-Boot tree | `ghcr.io/armbian/shallow/u-boot-git:latest` | Single-packfile `u-boot-complete.git.tar` |

## Repository layout

```
.
├── .github/workflows/            # Scheduled maintenance workflows
├── lib.sh                        # Shared Bash helpers (retry, mirrored fetch, trim, …)
├── oras_upload.sh                # Downloads/caches the ORAS CLI and pushes one file as an OCI artifact
├── work_kernel_tree.sh           # Builds the kernel tree, exports shallow + complete bundles
├── work_uboot_tree.sh            # Builds the combined U-Boot tree, exports a single tarball
├── LICENSE                       # GPL-3.0
└── README.md
```

## How it works

The two `work_*_tree.sh` scripts are the heart of the pipeline. They:

1. `git init` a persistent worktree under `${BASE_WORK_DIR}` (cached between CI runs for the kernel job).
2. Seed / update the tree using `git_fetch_mirrored` from `lib.sh`, which walks a list of mirrors on retry, distinguishes "mirror lags upstream" from "ref really is missing" (`GIT_FETCH_NO_SUCH_REF`), and applies growing backoff and per-attempt timeouts (`timeout(1)`).
3. Post-process (drop remotes, expire reflogs, aggressive repack into a single packfile, `pack-refs --all --prune`).
4. Emit `.git.tar` files into an output directory.

`oras_upload.sh` then downloads (and caches under `${DIR_ORAS}`) the ORAS CLI matching the runner's OS/arch, logs in to `ghcr.io` using the workflow's `GITHUB_TOKEN`, and pushes each tarball as an OCI artifact layer (`application/vnd.unknown.layer.v1+tar`).

Mirror preferences are documented inline in `work_kernel_tree.sh` (`GIT_TORVALDS_MIRRORS`, `GIT_STABLE_MIRRORS`) and reflect real observed behaviour — notably that `kernel.googlesource.com` can be days behind on fresh `-rc1` tags, which is precisely what the shallow export anchors on.

## Running locally

The scripts are intended to run in Ubuntu-based GitHub runners but can be exercised locally. They require:

- Bash, `git`, `curl`, `wget`, `jq`, `tar`, `awk`, `sed`, `grep`, `md5sum`, `timeout` (coreutils).
- Network access to kernel.org, GitHub, and (for the kernel job) `kernel.googlesource.com`.
- Roughly 25 GiB of free disk for the kernel job; ~1.5 GiB for the U-Boot job.
- For publishing: a Docker/`ghcr.io` login and `packages: write` on the target repository.

Typical invocation:

```bash
BASE_WORK_DIR=/tmp/workdir bash work_kernel_tree.sh
BASE_WORK_DIR=/tmp/workdir bash work_uboot_tree.sh

# then, per artifact:
TARGET_OCI="ghcr.io/<owner>/shallow/kernel-git:latest" \
TARGET_FULL_FILE_PATH="/tmp/workdir/kernel/output_oras/linux-complete.git.tar" \
  bash oras_upload.sh
```

Relevant environment knobs (see the scripts for the full list):

- `BASE_WORK_DIR` — root of all working state and outputs.
- `ONLINE` (kernel) — set to anything other than `yes` to skip live fetches and rebuild bundles from the existing worktree.
- `MAINLINE_UBOOT_URL`, `MAX_TARBALL_MIB` (U-Boot).
- `RETRY_MAX_ATTEMPTS`, `RETRY_BASE_DELAY`, `RETRY_TIMEOUT` (`lib.sh`).
- `ORAS_VERSION`, `DIR_ORAS`, `TARGET_OCI`, `TARGET_FULL_FILE_PATH` (`oras_upload.sh`).

## Built with

- **Bash** scripts (`lib.sh`, `work_kernel_tree.sh`, `work_uboot_tree.sh`, `oras_upload.sh`) — the actual pipeline logic.
- **YAML** GitHub Actions workflows under `.github/workflows/` for scheduling, caching, publishing and self-healing reruns.
- **git**, **[ORAS](https://oras.land/)**, and standard Unix tooling (`jq`, `curl`, `wget`, `tar`, `timeout`, …).

## Continuous integration

For an overview of this repository's workflows and their current status, see:

<https://actions.armbian.com/?repo=shallow>

## License

Licensed under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE) for the full text.

## More about Armbian

- Project site: <https://www.armbian.com>
- Documentation: <https://docs.armbian.com>
