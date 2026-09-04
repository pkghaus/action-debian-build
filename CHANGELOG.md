# Changelog

All notable changes to this project are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Consumers pin the floating major (`@v1`), which always points at the newest
`v1.x.y` release. Anything that changes the calling contract — action inputs,
`package.conf` keys, artifact names — is a breaking change and gets a new
major. Exact tags never move.

## [1.7.0] - 2026-09-04

### Added

- Each build phase reports how long it took as it finishes, and the run reports
  a total. A leg used to be a single number with no way to separate an image
  pull from a dependency install from a compile. A build that dies partway
  still reports the phases before it, and reports no duration for the one that
  did not finish.

### Fixed

- The rustup installer is fetched on the same retry budget as the upstream
  clone, and to a file rather than piped into `sh`. In a pipe the status the
  shell sees is `sh`'s, so a truncated download could report success on a
  partial install.
- The dispatch that tells the archive a tag is ready is retried. Its failure
  was silent and unrepaired: the tag exists, the archive is never told, and
  nothing re-fires it.

## [1.6.0] - 2026-09-02

### Added

- `debian/upstream-commit`, written before the build, for packages whose build
  embeds the upstream revision. It travels inside the `.dsc`, so a rebuild
  resolves the same value; an environment variable cannot, because dpkg records
  only `DEB_BUILD_OPTIONS` and `SOURCE_DATE_EPOCH`. A native package gets none.

## [1.5.0] - 2026-09-02

### Changed

- A native package is its own source. Where `debian/source/format` says native
  the packaging directory is copied instead of an upstream being cloned, and
  `UPSTREAM` or `VERSION` in `package.conf` is refused rather than ignored: a
  leftover value is likelier to be a stale file than an intention. The source
  tree takes its name from the changelog.

## [1.4.0] - 2026-09-01

### Added

- Builds emit their source package (`.dsc` plus tarballs) into `debs/`, and
  record `Build-Path`. Those are the two things `debrebuild` needs: given a
  `.buildinfo` alone it resolves the whole environment from
  `snapshot.debian.org` and then fails to find the source, and its mmdebstrap
  builder dies in `dirname()` without the path.
- `.source` names the compiler that ran (`Rustc:`, `Go:`), read from inside the
  source tree so it reports the toolchain `rust-toolchain.toml` or `go.mod`
  selected rather than the one rustup installed.

### Fixed

- Every Go package embedded git metadata that nothing rebuilding it could
  reproduce. `go build` stamps `vcs.revision`, `vcs.time` and `vcs.modified`
  into the binary whenever it finds a repository, the builder clones one, and a
  source package cannot carry it. The clone's `.git` is removed once the commit
  has been read. Found by rebuilding croc with `debrebuild`: 160 bytes of
  difference, all of it this.

### Changed

- A Rust package should declare `Build-Depends: rustup` instead of setting
  `TOOLCHAIN=rust`. Debian ships rustup, so the bootstrap lands in the
  `.buildinfo` where a rebuilder can resolve it, and the pin in
  `rust-toolchain.toml` or `debian/rules` selects the compiler -- the same shape
  Go already had. `TOOLCHAIN=rust` still works; setting both is refused.
- rustup installs with `--default-toolchain none`. The version comes from the
  package (`rust-toolchain.toml`, or `RUSTUP_TOOLCHAIN` in `debian/rules`) and
  rustup fetches it on first use; installing `stable` as well downloaded a
  second complete toolchain, because rustup treats the channel and the version
  it points at as separate installs. A Rust package naming no version now fails
  instead of building with whatever stable is that day.
- Builds happen in `/build/<source-dir>` instead of a `mktemp` directory, so the
  published `Build-Path` is the same on every leg. Packages whose output depends
  on the build path -- Rust ones do -- therefore produce different bytes than
  before, and become reproducible for anyone rebuilding at the recorded path.
- A build fails if any file under `debian/` predates the changelog entry.
  `dpkg-source` preserves mtimes older than `SOURCE_DATE_EPOCH` while
  normalising newer ones, which would make one leg's source package differ from
  another's.

## [1.3.2] - 2026-08-31

### Fixed

- `DEP8_EXTRA_DEBS` never worked on a GitHub runner. The debs are fetched by a
  container, so they land root-owned, and `autopkgtest` runs as the runner user
  and hard-links them into its output directory: under
  `fs.protected_hardlinks=1` that is EPERM. They are chowned to the runner
  before `autopkgtest` sees them.

## [1.3.1] - 2026-08-31

### Fixed

- A caller building several packages in one run verified only one of them. The
  reusable workflow's concurrency group did not include `working_directory`, so
  every leg of a matrix shared a group and `cancel-in-progress` cancelled all
  but the last. The cancelled legs reported "cancelled", not failure, so the run
  was green.

## [1.3.0] - 2026-08-29

### Added

- `working_directory` on the reusable workflow: build a package held in a
  subdirectory, which is what lets one repository hold every package.
- A `.source` sidecar beside each `.deb`, naming the upstream commit built.

### Changed

- The builder image is resolved to a digest before use, rather than pulled by
  tag.
- The entrypoint moved out of `/usr/local/bin`, so `.buildinfo` no longer
  reports `Build-Tainted-By: usr-local-has-programs`.

## [1.2.0] - 2026-08-27

### Added

- `DEP8_EXTRA_DEBS` in `package.conf`: packages from this archive that the DEP-8
  testbed needs, fetched and handed to autopkgtest alongside the built package.
  The testbed is Debian only, so a dependency Debian does not carry cannot
  otherwise resolve. Space-separated; a value that is not a list of Debian
  package names fails the build before anything is installed.

## [1.1.0] - 2026-08-26

### Added

- DEP-8 tests run after the build for any package shipping `debian/tests/`.
  A package without `debian/tests/control` is unaffected. Set `dep8: "off"` on
  `build.yml`, or `DEP8: "off"` on the action, to skip them.

### Changed

- The reusable `build.yml` now calls this repository's own action instead of
  reimplementing the `docker run`.

### Fixed

- `DBGSYM` rejects a value it does not understand. It was compared against `1`
  alone, so `DBGSYM=yes` silently disabled the package it was written to
  enable. `off` and `on` are now accepted alongside `0` and `1`.

## [1.0.0] - 2026-08-14

First release.

### Added

- `action-debian-build`: builds a Debian package from an upstream git tag and a
  `debian/` directory, with `SUITE`, `IMAGE` and `WORKING_DIRECTORY` inputs.
- Reusable `build.yml` for validation: every suite and architecture in
  parallel, artifacts kept briefly for inspection. Publishing belongs to the
  pkg.haus APT archive, which builds from source itself.
- A validated tag notifies the archive: `build.yml`'s final job fires
  `repository_dispatch` at `pkghaus/apt` when the caller passes the optional
  `APT_DISPATCH_TOKEN` secret (`secrets: inherit`); without it the job is a
  no-op.
- Builder images at `ghcr.io/<owner>/deb-builder:<suite>` for `trixie`,
  `testing` and `unstable`, as multi-arch manifests covering `amd64` and
  `arm64`, carrying SLSA provenance and an SBOM. `BASE_IMAGE` allows a
  non-Debian base.
- `package.conf` as the per-repository contract: `UPSTREAM`, `VERSION`,
  `TOOLCHAIN`, `DBGSYM`, `LINTIAN`, `SETUP_HOOK`.
- Upstream clones are retried five times with exponential backoff, clearing any
  partial checkout first.
- Builds run through `dpkg-buildpackage`, so a `.buildinfo` recording the build
  environment is collected alongside the package.
- `lintian` runs on the result; `LINTIAN` selects `off`, `warn` or `error`.
- `DBGSYM=1` builds the automatic `-dbgsym` package; the default suppresses it
  with `noautodbgsym` so it is never built.
- Versions carry a suite qualifier (`~haus13+1` for stable, `~testing1` for
  testing, none for unstable), so one pooled APT archive can serve every suite
  and upgrades order correctly across them. Artifacts keep their canonical
  Debian filenames.

[Unreleased]: https://github.com/pkghaus/action-debian-build/compare/v1.7.0...HEAD
[1.7.0]: https://github.com/pkghaus/action-debian-build/compare/v1.6.0...v1.7.0
[1.6.0]: https://github.com/pkghaus/action-debian-build/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/pkghaus/action-debian-build/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/pkghaus/action-debian-build/compare/v1.3.2...v1.4.0
[1.3.2]: https://github.com/pkghaus/action-debian-build/compare/v1.3.1...v1.3.2
[1.3.1]: https://github.com/pkghaus/action-debian-build/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/pkghaus/action-debian-build/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/pkghaus/action-debian-build/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/pkghaus/action-debian-build/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/pkghaus/action-debian-build/releases/tag/v1.0.0
