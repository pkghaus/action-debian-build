# Changelog

All notable changes to this project are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Consumers pin the floating major (`@v1`), which always points at the newest
`v1.x.y` release. Anything that changes the calling contract — action inputs,
`package.conf` keys, artifact names — is a breaking change and gets a new
major. Exact tags never move.

## [1.8.0] - 2026-09-06

### Fixed

- The orig tarball is stamped with upstream's commit date, not the changelog's,
  so every Debian revision of one upstream version produces the same bytes.
- The Docker Hub pull for the DEP-8 testbed is retried, on the same budget as
  the upstream clone.

## [1.7.0] - 2026-09-04

### Added

- Per-phase timings, and a total for the run. A build that dies partway still
  reports the phases that finished.

### Fixed

- The rustup installer is fetched on the clone's retry budget, and to a file
  rather than piped into `sh`.
- The `repository_dispatch` that tells the archive a tag is ready is retried.

## [1.6.0] - 2026-09-02

### Added

- `debian/upstream-commit`, for packages whose build embeds the upstream
  revision. It ships inside the `.dsc`; a native package gets none.

## [1.5.0] - 2026-09-02

### Changed

- A native package is its own source: the packaging directory is copied rather
  than an upstream cloned, and the source tree is named from the changelog.
  **`UPSTREAM` or `VERSION` in `package.conf` is now refused**, not ignored.

## [1.4.0] - 2026-09-01

### Added

- Builds emit their source package (`.dsc` plus tarballs) into `debs/` and
  record `Build-Path`, which are the two things `debrebuild` needs.
- `.source` names the compiler that ran (`Rustc:`, `Go:`), read from inside the
  source tree.

### Fixed

- The clone's `.git` is removed once the commit has been read, so `go build`
  stops stamping `vcs.revision` into every Go binary.

### Changed

- A Rust package declares `Build-Depends: rustup` instead of setting
  `TOOLCHAIN=rust`; the pin in `rust-toolchain.toml` or `debian/rules` selects
  the compiler. `TOOLCHAIN=rust` still works, and setting both is refused.
- rustup installs with `--default-toolchain none`. **A Rust package naming no
  version now fails** rather than building against whatever stable is that day.
- Builds happen in `/build/<source-dir>` rather than a `mktemp` directory, so
  `Build-Path` is identical on every leg. **A path-dependent package produces
  different bytes than before** and becomes reproducible at the recorded path.
- A build fails if any file under `debian/` predates the changelog entry.

## [1.3.2] - 2026-08-31

### Fixed

- `DEP8_EXTRA_DEBS` works on a GitHub runner: the fetched debs are chowned to
  the runner before `autopkgtest` hard-links them.

## [1.3.1] - 2026-08-31

### Fixed

- A caller building several packages in one run verifies all of them: the
  reusable workflow's concurrency group includes `working_directory`.

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

- `DEP8_EXTRA_DEBS` in `package.conf`: space-separated packages from this
  archive that the DEP-8 testbed needs. A malformed value fails the build.

## [1.1.0] - 2026-08-26

### Added

- DEP-8 tests run after the build for any package shipping `debian/tests/`.
  Set `dep8: "off"` on `build.yml`, or `DEP8: "off"` on the action, to skip.

### Changed

- The reusable `build.yml` calls this repository's own action instead of
  reimplementing the `docker run`.

### Fixed

- `DBGSYM` rejects a value it does not understand. `off` and `on` are accepted
  alongside `0` and `1`; previously anything but `1` silently meant off.

## [1.0.0] - 2026-08-14

First release.

### Added

- `action-debian-build`: builds a Debian package from an upstream git tag and a
  `debian/` directory. Inputs `SUITE`, `IMAGE`, `WORKING_DIRECTORY`.
- Reusable `build.yml` for validation: every suite and architecture in
  parallel, artifacts kept briefly for inspection.
- A validated tag notifies the archive by `repository_dispatch`, when the
  caller passes the optional `APT_DISPATCH_TOKEN` secret. Otherwise a no-op.
- Builder images at `ghcr.io/<owner>/deb-builder:<suite>` for `trixie`,
  `testing` and `unstable`: multi-arch amd64 and arm64, carrying SLSA
  provenance and an SBOM. `BASE_IMAGE` allows a non-Debian base.
- `package.conf` as the per-repository contract: `UPSTREAM`, `VERSION`,
  `TOOLCHAIN`, `DBGSYM`, `LINTIAN`, `SETUP_HOOK`.
- Upstream clones are retried five times with exponential backoff.
- Builds run through `dpkg-buildpackage`, so a `.buildinfo` is collected
  alongside the package.
- `lintian` runs on the result; `LINTIAN` selects `off`, `warn` or `error`.
- `DBGSYM=1` builds the automatic `-dbgsym` package; the default suppresses it.
- Versions carry a suite qualifier (`~haus13+1` stable, `~testing1` testing,
  none unstable) so one pooled archive serves every suite and upgrades order
  correctly. Artifacts keep canonical Debian filenames.

[Unreleased]: https://github.com/pkghaus/action-debian-build/compare/v1.8.0...HEAD
[1.8.0]: https://github.com/pkghaus/action-debian-build/compare/v1.7.0...v1.8.0
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
