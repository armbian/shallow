<h2 align="center">
  <a href=#><img src="https://raw.githubusercontent.com/armbian/.github/master/profile/logosmall.png" alt="Armbian logo"></a>
  <br><br>
</h2>

# Armbian Shallow Git Trees

## Purpose of This Repository

This repository automates the preparation and daily publication of **shallow Linux kernel git bundles** and a **combined u-boot git tree**, so that Armbian's CI and end-user builds can seed their working trees from small, CDN-fronted OCI artifacts instead of cloning multi-gigabyte upstream repositories on every run.

## Why

Full kernel trees can be several gigabytes in size and take considerable time and resources to clone. While shallow clones reduce this overhead, fetching them directly still places significant load on the source servers.

To address this, `kernel.org` provides [pre-generated git bundles](https://git-scm.com/docs/git-bundle), which are simple archive files downloadable via CDN. These are the recommended method for CI usage according to [kernel.org best practices](https://www.kernel.org/best-way-to-do-linux-clones-for-your-ci.html).

This repository:

- Automates downloading of upstream kernel bundles.
- Updates them from live git sources.
- Generates new, optimized shallow bundles for downstream use.
- Ensures all relevant version tags are included (including `-rc` tags).
- Executes scheduled daily updates using GitHub Actions and caching mechanisms.

> Optimized shallow kernel bundles are ~300 MB — significantly smaller than full clones and much faster to work with.

## Kernel trees

The kernel side reads the current release versions from `https://www.kernel.org/releases.json`, adds a couple of extra legacy branches Armbian still supports (`4.9`, `4.4`), and produces:

- One **shallow** `.git.tar` per wanted kernel version, published to `ghcr.io/armbian/shallow/kernel-git-shallow-<version>:latest`.
- One **complete** kernel `.git.tar` (too large for GitHub Releases, hence ORAS/`ghcr.io`), published to `ghcr.io/armbian/shallow/kernel-git:latest`.

The cold `clone.bundle` is always fetched from `kernel.org`, while live updates are pulled either from Google's `kernel.googlesource.com` HTTPS mirrors (default) or directly from `git.kernel.org`, with automatic fallback between the two when the primary refuses a fetch.

## U-Boot tree

The same repository also prepares a **combined u-boot git tree**, for the same reason and via the same mechanism — but with no shallow variant, since the whole tree is small enough that one complete artifact serves every consumer.

It is seeded with:

- **Mainline u-boot** — `master` plus every tag. Nearly every Armbian board pins its `BOOTBRANCH` to a `tag:vYYYY.MM`, so shipping the tags is what makes those builds a cache hit rather than a fetch.
- **Vendor forks** listed in the `EXTRA_TREES` table in `work_uboot_tree.sh`, whose branches land under `refs/heads/<prefix>/`. Currently just Radxa's `next-dev*`, which the `rk35xx`, `rockchip-rk3588` and `rockchip-rv1106` families build from.

The tree is also the shared object store for every *other* u-boot fork Armbian builds (TI, SolidRun, NXP, Xilinx, hardkernel, orangepi-xunlong, CoreELEC, …) — those are not seeded, but they fetch into a tree that already holds mainline's history, so their fetches stay small.

> The u-boot artifact is ~390 MB, single-packfile.

Published daily to `ghcr.io/armbian/shallow/u-boot-git:latest`, alongside the kernel ones.

## Repository layout

```
lib.sh                 # shared bash helpers (retry-with-timeout, trimming)
oras_upload.sh         # downloads a pinned oras binary and pushes a file to ghcr.io
work_kernel_tree.sh    # builds the shallow + complete kernel .git tarballs
work_uboot_tree.sh     # builds the combined u-boot .git tarball
.github/workflows/     # scheduled maintenance workflows (see CI below)
```

## Built with

- **Bash** shell scripts (`lib.sh`, `oras_upload.sh`, `work_kernel_tree.sh`, `work_uboot_tree.sh`) — all `#!/usr/bin/env bash`, `set -e`.
- **git** — `git bundle`, `git fetch`, `git repack`, `git pack-refs`, `git reflog expire`, `git ls-remote`, `git worktree`.
- **[ORAS](https://oras.land/)** (`v0.16.0`, pinned in `oras_upload.sh`) — pushes the resulting `.git.tar` files as OCI artifacts to `ghcr.io`.
- **jq**, **curl**, **wget**, **tar**, **coreutils** (`timeout`, `md5sum`, `awk`, `sed`) — standard runner tooling used by the scripts.
- **GitHub Actions** (YAML workflows under `.github/workflows/`) — schedule the daily runs, cache the kernel worktree between runs, and log in to GHCR.

## Running locally

Both worker scripts honour a `BASE_WORK_DIR` env var and default to sensible paths otherwise:

```bash
# Build the kernel shallow + complete tars
BASE_WORK_DIR=/tmp/workdir bash work_kernel_tree.sh

# Build the combined u-boot tar
BASE_WORK_DIR=/tmp/workdir bash work_uboot_tree.sh
```

Uploading requires being logged in to a container registry and setting `TARGET_OCI` and `TARGET_FULL_FILE_PATH`:

```bash
TARGET_OCI="ghcr.io/<owner>/<repo>/kernel-git:latest" \
TARGET_FULL_FILE_PATH="/tmp/workdir/kernel/output_oras/linux-complete.git.tar" \
  bash oras_upload.sh
```

Useful knobs exposed by the scripts:

| Variable | Where | Purpose |
| --- | --- | --- |
| `BASE_WORK_DIR` | both work scripts | Root of the scratch tree (default varies per script). |
| `GIT_SOURCE` | `work_kernel_tree.sh` | `google` (default) or `kernelorg` — chooses the live fetch mirror. |
| `ONLINE` | `work_kernel_tree.sh` | Set to `no` to skip live fetches and reuse a cached worktree. |
| `MAINLINE_UBOOT_URL` | `work_uboot_tree.sh` | Override the mainline u-boot remote. |
| `MAX_TARBALL_MIB` | `work_uboot_tree.sh` | Sanity ceiling that refuses to publish a bloated artifact. |
| `RETRY_MAX_ATTEMPTS`, `RETRY_BASE_DELAY`, `RETRY_TIMEOUT` | `lib.sh` | Tune the retry-with-timeout wrapper used around network/git operations. |
| `ORAS_VERSION`, `DIR_ORAS` | `oras_upload.sh` | Pinned oras version and cache directory. |

## Consuming the artifacts

The artifacts are published as OCI artifacts on GitHub Container Registry and can be pulled with `oras pull`. For the u-boot tree, for example:

```
ghcr.io/armbian/shallow/u-boot-git:latest
```

For kernels, one artifact per version plus the complete tree:

```
ghcr.io/armbian/shallow/kernel-git-shallow-<version>:latest
ghcr.io/armbian/shallow/kernel-git:latest
```

Each artifact contains a single `.git.tar` of a bare-ish git directory that the Armbian build framework extracts and hangs `git worktree`s off.

## Continuous Integration

The daily rebuild and publish jobs, plus a watchdog that reruns failed jobs, run as scheduled GitHub Actions workflows in `.github/workflows/`. For live status and per-workflow history, see the Armbian CI overview for this repo:

<https://actions.armbian.com/?repo=shallow>

## License

Distributed under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE) for the full text.

## Related

- Armbian project website — <https://www.armbian.com>
- Armbian documentation — <https://docs.armbian.com>
