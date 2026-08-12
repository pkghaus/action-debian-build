# Security

## Reporting

Open a [private vulnerability report](https://github.com/pkghaus/action-debian-build/security/advisories/new)
rather than a public issue.

## What this pipeline trusts

A packaging repository is trusted; the upstream project it builds is not. Every
build clones an upstream project at a tag and then runs code from it — its
`configure`, its makefiles, its `build.rs`, whatever `debian/rules` invokes. That
code executes as root inside the container, so the boundaries that matter are the
ones around it.

- **The checkout carries no credentials.** `actions/checkout` persists the
  workflow token into `.git/config` by default, and the build mounts the
  checkout into the container, which would put that token within reach of
  upstream build code. Every checkout in this repository sets
  `persist-credentials: false`. Nothing in the build needs git credentials — the
  upstream clone is unauthenticated.
- **The build job cannot write to your repository.** Everything here runs with
  `contents: read`; nothing in this repository publishes anywhere. Publishing
  belongs to the pkg.haus APT archive, which runs no upstream code at publish
  time.
- **The container is disposable.** `docker run --rm` with one bind mount, and
  nothing is reused between builds.

Running as root inside the container is deliberate: `apt-get` needs it to install
build dependencies. The isolation boundary is the container, not the user.

## Supply chain

- **Actions are pinned to full commit SHAs**, with the version in a trailing
  comment. A tag can be moved by anyone who compromises the action's repository;
  a SHA cannot. Dependabot proposes updates weekly.
- **The actionlint image is pinned by digest** for the same reason.
- **Published images carry SLSA provenance and an SBOM**, attached by buildx and
  attested through `actions/attest-build-provenance`. Verify one with:

  ```sh
  gh attestation verify oci://ghcr.io/pkghaus/deb-builder:trixie \
      --owner pkghaus
  ```

- **`GITHUB_TOKEN` never reaches a script as interpolated text.** Expressions are
  passed through the environment, which is what GitHub recommends to avoid script
  injection.

### Known unpinned dependencies

Two things float deliberately:

- **`debian:<suite>-slim`**, because the whole point is to track a Debian suite.
  Pinning it by digest would freeze the base and defeat the weekly rebuild.
- **The buildkit image** used by the `docker-container` buildx driver, which
  buildx resolves itself.

Both run only in image builds, never in a package build.
