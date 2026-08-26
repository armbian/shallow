<h2 align="center">
  <img src="https://raw.githubusercontent.com/armbian/.github/master/profile/logosmall.png" alt="Armbian logo">
  <br><br>
</h2>

This repository automates the preparation and distribution of **shallow Linux kernel bundles** optimized for use in CI/CD environments.

Full kernel trees can be several gigabytes in size and take considerable time and resources to clone. While shallow clones reduce this overhead, fetching them directly still places significant load on the source servers.

To address this, `kernel.org` provides [pre-generated git bundles](https://git-scm.com/docs/git-bundle), which are simple archive files downloadable via CDN. These are the recommended method for CI usage according to [kernel.org best practices](https://www.kernel.org/best-way-to-do-linux-clones-for-your-ci.html).

This repository:

- Automates downloading of upstream kernel bundles.
- Updates them from live git sources.
- Generates new, optimized shallow bundles for downstream use.
- Ensures all relevant version tags are included (including `-rc` tags).
- Executes scheduled daily updates using GitHub Actions and caching mechanisms.

> Optimized shallow bundles are ~300 MB — significantly smaller than full clones and much faster to work with.

## U-Boot trees

The same repository also prepares a **combined u-boot git tree**, for the same reason and via the
same mechanism — but with no shallow variant, since the whole tree is small enough that one
complete artifact serves every consumer.

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

Published daily to `ghcr.io/armbian/shallow/u-boot-git:latest`, alongside the kernel ones.
