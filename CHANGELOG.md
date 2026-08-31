# Changelog

All notable changes to this project are documented here, following
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Consumers pin the floating major (`@v1`), which always points at the newest
`v1.x.y` release. Anything that changes the calling contract — action inputs,
`package.conf` keys, artifact names — is a breaking change and gets a new
major. Exact tags never move.

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

[Unreleased]: https://github.com/pkghaus/action-debian-build/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/pkghaus/action-debian-build/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/pkghaus/action-debian-build/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/pkghaus/action-debian-build/releases/tag/v1.0.0
