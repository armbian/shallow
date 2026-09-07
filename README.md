<h2 align="center">
  <a href=#><img src="https://raw.githubusercontent.com/armbian/.github/master/profile/logosmall.png" alt="Armbian logo"></a>
  <br><br>
</h2>

# Armbian Shallow Git Trees

## Purpose of This Repository

This repository automates the daily preparation and publication of **shallow Linux kernel git bundles** and a **combined u-boot git tree**, distributed as OCI artifacts on `ghcr.io`. These pre-built trees dramatically speed up Armbian's CI/CD builds by eliminating the need to clone multi-gigabyte git histories from upstream on every run.

## Why

Full kernel trees can be several gigabytes in size and take considerable time and resources to clone. While shallow clones reduce this overhead, fetching them directly still places significant load on the source servers.

To address this, `kernel.org` provides [pre-generated git bundles](https://git-scm.com/docs/git-bundle), which are simple archive files downloadable via CDN. These are the recommended method for CI usage according to [kernel.org best practices](https://www.kernel.org/best-way-to-do-linux-clones-for-your-ci.html).

## What it does

- Downloads upstream kernel `clone.bundle` from kernel.org (via CDN).
- Updates the tree from the live Torvalds and stable git mirrors (Google's HTTPS mirrors by default, with a kernel.org fallback).
- Generates optimized **shallow bundles per kernel version** (one artifact per `MAJOR.MINOR` derived from `kernel.org/releases.json`, plus legacy `4.9` and `4.4`), including relevant version tags (`-rc` included).
- Also publishes a **single complete** kernel tree tarball.
- Builds and publishes a **combined u-boot git tree** seeded with mainline u-boot plus selected vendor forks.
- Runs on a daily schedule via GitHub Actions, with a watchdog that reruns failed jobs.

> Optimized shallow kernel bundles are ~300 MB — significantly smaller than full clones and much faster to work with.

## Published artifacts

All artifacts are pushed to `ghcr.io/armbian/shallow/*` using [ORAS](https://oras.land/) and tagged `:latest`.

| Artifact | OCI reference |
| --- | --- |
| Shallow kernel bundle (per `MAJOR.MINOR`) | `ghcr.io/armbian/shallow/kernel-git-shallow-<version>:latest` |
| Complete kernel tree tarball | `ghcr.io/armbian/shallow/kernel-git:latest` |
| Combined u-boot git tree | `ghcr.io/armbian/shallow/u-boot-git:latest` |

## U-Boot trees

The u-boot artifact is a single combined git tree, prepared for the same reason and via the
same mechanism as the kernel — but with no shallow variant, since the whole tree is small enough
that one complete artifact serves every consumer.

It is seeded with:

- **Mainline u-boot** — `master` plus every tag. Nearly every Armbian board pins its `BOOTBRANCH`
  to a `tag:vYYYY.MM`, so shipping the tags is what makes those builds a cache hit rather than a
  fetch.
- **Vendor forks** listed in the `EXTRA_TREES` table in `work_uboot_tree.sh`, whose branches land
  under `refs/heads/<prefix>/`. Currently just Radxa's `next-dev*`, which the `rk35xx`,
  `rockchip-rk3588` and `rockchip-rv1106` families build from.

The tree is also the shared object store for every *other* u-boot fork Armbian builds (TI,
SolidRun, NXP, Xilinx, hardkernel, orangepi-xunlong, CoreELEC, …) — those are not seeded, but they
fetch into a tree that already holds mainline's history, so their fetches stay small.

> The u-boot artifact is ~390 MB, single-packfile.

## Repository layout

```
.
├── .github/workflows/     # GitHub Actions workflows (YAML)
├── lib.sh                 # Shared Bash helpers: display_alert, run_with_retries[_capture], trimmed
├── oras_upload.sh         # Downloads/caches the oras binary and pushes a file as an OCI artifact
├── work_kernel_tree.sh    # Builds shallow per-version + complete kernel trees
├── work_uboot_tree.sh     # Builds the combined u-boot git tree
├── LICENSE                # GPL-3.0
└── README.md
```

## How it works

1. **Preparation** (`work_kernel_tree.sh`, `work_uboot_tree.sh`)
   - Initializes a bare-ish git worktree, adds upstream remotes, and fetches history and tags. Network operations are wrapped in `run_with_retries` (from `lib.sh`) with exponential back-off and per-attempt timeouts to survive flaky mirrors.
   - The kernel job seeds from kernel.org's `clone.bundle`, then updates from live Torvalds/stable mirrors; the u-boot job fetches mainline plus vendor forks (with per-fork `refs/heads/<prefix>/` namespacing and `--no-tags` to avoid tag collisions).
2. **Post-processing** (u-boot)
   - Removes remotes, expires reflogs, and repacks to a single packfile so consumers get one clean, minimal packfile.
3. **Publication** (`oras_upload.sh`)
   - Downloads (and caches) the `oras` binary matching the runner's OS/arch, then pushes the resulting `.tar` to `ghcr.io` under the configured `TARGET_OCI` reference.

## Running locally

The scripts are plain Bash and can be run outside CI. `BASE_WORK_DIR` controls where trees are built.

```bash
# Build kernel trees (shallow per-version + complete) under /tmp/workdir/kernel
BASE_WORK_DIR=/tmp/workdir bash work_kernel_tree.sh

# Build the combined u-boot tree under /tmp/workdir/u-boot
BASE_WORK_DIR=/tmp/workdir bash work_uboot_tree.sh
```

Selected environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `BASE_WORK_DIR` | (see script) | Root working directory for trees and outputs |
| `GIT_SOURCE` | `google` | Live-fetch mirror for kernel: `google` or `kernelorg` |
| `MAINLINE_UBOOT_URL` | `https://github.com/u-boot/u-boot.git` | Mainline u-boot remote |
| `MAX_TARBALL_MIB` | `2048` | Size guard for the u-boot artifact |
| `RETRY_MAX_ATTEMPTS` | `5` | Max attempts for `run_with_retries` |
| `RETRY_BASE_DELAY` | `10` | Initial retry delay (seconds), doubling per attempt |
| `RETRY_TIMEOUT` | `600` | Per-attempt timeout (seconds), doubling per attempt |
| `ORAS_VERSION` | `0.16.0` | ORAS release used by `oras_upload.sh` |
| `TARGET_OCI`, `TARGET_FULL_FILE_PATH` | — | Required inputs for `oras_upload.sh` |

## Requirements

- **Bash** (scripts use `#!/usr/bin/env bash`, arrays, `mapfile`, etc.)
- **git**, **curl**, **wget**, **jq**, **tar**, **awk**, **sed**, **timeout** (coreutils)
- **oras** — downloaded on demand by `oras_upload.sh`
- A container registry login (the workflows use the GitHub Actions built-in token to push to `ghcr.io`)

## Continuous Integration

Trees are rebuilt and republished daily by scheduled GitHub Actions, with a watchdog that reruns failed jobs. See the Armbian CI overview for this repository:

<https://actions.armbian.com/?repo=shallow>

## License

Licensed under the [GNU General Public License v3.0](LICENSE).

## Related links

- Armbian project: <https://www.armbian.com>
- Armbian documentation: <https://docs.armbian.com>
- kernel.org best practices for CI clones: <https://www.kernel.org/best-way-to-do-linux-clones-for-your-ci.html>
