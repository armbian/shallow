<h2 align="center">
  <a href=#><img src="https://raw.githubusercontent.com/armbian/.github/master/profile/logosmall.png" alt="Armbian logo"></a>
  <br><br>
</h2>

# Armbian Shallow Git Trees

## Purpose of This Repository

This repository automates the preparation and daily publication of **shallow Linux kernel git bundles** and a **combined u-boot git tree**, distributed as OCI artifacts so Armbian's CI/CD (and end-user) builds can bootstrap their kernel and u-boot source trees from a CDN-fronted registry instead of cloning multi-gigabyte upstream repositories.

## Why

Full kernel trees can be several gigabytes in size and take considerable time and resources to clone. While shallow clones reduce this overhead, fetching them directly still places significant load on the source servers.

To address this, `kernel.org` provides [pre-generated git bundles](https://git-scm.com/docs/git-bundle), which are simple archive files downloadable via CDN. These are the recommended method for CI usage according to [kernel.org best practices](https://www.kernel.org/best-way-to-do-linux-clones-for-your-ci.html).

This repository:

- Downloads upstream kernel bundles from `kernel.org` and updates them from live git sources.
- Generates optimized shallow bundles per supported kernel version (including `-rc` tags).
- Prepares a combined u-boot git tree seeded with mainline plus selected vendor forks.
- Publishes the resulting artifacts daily to `ghcr.io` via [ORAS](https://oras.land/).

> Optimized shallow kernel bundles are ~300 MB, much smaller than full clones and much faster to work with. The u-boot artifact is ~390 MB, single-packfile.

## Kernel trees

`work_kernel_tree.sh` reads the currently supported kernel versions from
[`kernel.org/releases.json`](https://www.kernel.org/releases.json), plus a couple of legacy
versions Armbian still uses (`4.9`, `4.4`), and produces:

- One **shallow** bundle per version, published as
  `ghcr.io/armbian/shallow/kernel-git-shallow-<version>:latest`.
- One **complete** tree, published as `ghcr.io/armbian/shallow/kernel-git:latest`.

Fetches rotate over three mirrors — `git.kernel.org`, `github.com/torvalds/linux` (and
`github.com/gregkh/linux` for stable), and `kernel.googlesource.com` — with retries, timeouts,
and fast failover when a mirror lags behind on a fresh `-rc` tag.

## U-Boot trees

`work_uboot_tree.sh` prepares a **combined u-boot git tree**, for the same reason and via the
same mechanism — but with no shallow variant, since the whole tree is small enough that one
complete artifact serves every consumer.

It is seeded with:

- **Mainline u-boot** — `master` plus every tag. Nearly every Armbian board pins its
  `BOOTBRANCH` to a `tag:vYYYY.MM`, so shipping the tags is what makes those builds a cache hit
  rather than a fetch.
- **Vendor forks** listed in the `EXTRA_TREES` table in `work_uboot_tree.sh`, whose branches
  land under `refs/heads/<prefix>/`. Currently just Radxa's `next-dev*`, which the `rk35xx`,
  `rockchip-rk3588` and `rockchip-rv1106` families build from.

The tree is also the shared object store for every *other* u-boot fork Armbian builds (TI,
SolidRun, NXP, Xilinx, hardkernel, orangepi-xunlong, CoreELEC, …) — those are not seeded, but
they fetch into a tree that already holds mainline's history, so their fetches stay small.

Published daily to `ghcr.io/armbian/shallow/u-boot-git:latest`, alongside the kernel ones.

## Repository layout

```
lib.sh                 Shared Bash helpers: retries, timeouts, mirror-failover git fetch
work_kernel_tree.sh    Build the kernel worktree and export per-version shallow + complete tars
work_uboot_tree.sh     Build the combined u-boot worktree and export a single complete tar
oras_upload.sh         Download the ORAS CLI on demand and push a file as an OCI artifact
.github/workflows/     Scheduled maintenance jobs (kernel, u-boot, watchdog)
LICENSE                GPL-3.0
```

## Built with

- **Bash** shell scripts (`lib.sh`, `work_kernel_tree.sh`, `work_uboot_tree.sh`, `oras_upload.sh`).
- **git** (bundles, mirrored fetches, `repack`, `pack-refs`, `worktree`).
- **[ORAS](https://oras.land/)** for pushing tarballs as OCI artifacts to `ghcr.io`.
- Standard Unix tooling: `curl`, `wget`, `jq`, `tar`, `timeout`, `awk`, `sed`.
- **GitHub Actions** (YAML workflows) for scheduling, caching, and publication.

## Running locally

The scripts are designed to run in GitHub Actions but can be executed locally. They only need
Bash, git, and the usual Unix utilities; `oras_upload.sh` downloads the ORAS CLI itself on first
use.

```bash
# Build the per-version shallow bundles and the complete kernel tar under /tmp/workdir/kernel.
BASE_WORK_DIR="/tmp/workdir" bash work_kernel_tree.sh

# Build the combined u-boot tar under /tmp/workdir/u-boot.
BASE_WORK_DIR="/tmp/workdir" bash work_uboot_tree.sh

# Push a produced tar as an OCI artifact (requires prior `docker login ghcr.io`).
TARGET_OCI="ghcr.io/<owner>/<repo>/<name>:latest" \
TARGET_FULL_FILE_PATH="/tmp/workdir/kernel/output_oras/linux-complete.git.tar" \
bash oras_upload.sh
```

The kernel job is heavy: it downloads `kernel.org`'s `clone.bundle` (multi-GB) on first run and
resolves deltas locally. Subsequent runs reuse the worktree.

## Continuous integration

Scheduled maintenance workflows in `.github/workflows/` regenerate and publish the artifacts
daily, with a watchdog that reruns failed jobs. For an overview of this repository's workflows
and their current status, see:

<https://actions.armbian.com/?repo=shallow>

## Consumers

The published artifacts are consumed by the Armbian build framework:

- <https://github.com/armbian/build>

## Related

- Armbian documentation: <https://docs.armbian.com>
- Armbian project site: <https://www.armbian.com>
- kernel.org best practices for CI clones:
  <https://www.kernel.org/best-way-to-do-linux-clones-for-your-ci.html>

## License

Distributed under the **GNU General Public License v3.0**. See [`LICENSE`](LICENSE) for the
full text.
