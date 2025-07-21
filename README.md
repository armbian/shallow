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

> As of the `5.18.y` series, optimized shallow bundles are ~250 MB — significantly smaller than full clones and much faster to work with.
