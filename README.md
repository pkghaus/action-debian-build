# action-debian-build

Build a Debian package from an upstream git tag and your own `debian/` directory.

A packaging repository keeps only what is genuinely its own: the `debian/`
directory and a few lines of configuration. Cloning the upstream at a tag,
resolving build dependencies, running `dpkg-buildpackage`, checking the result
with `lintian` and collecting artifacts all live here and are shared.

## Usage

```yaml
- uses: actions/checkout@v7
- uses: pkghaus/action-debian-build@v1
  with:
    SUITE: trixie
```

| Input | Default | Meaning |
| --- | --- | --- |
| `SUITE` | `trixie` | Debian suite to build for; selects the builder image tag. |
| `IMAGE` | `ghcr.io/pkghaus/deb-builder` | Builder image, without the suite tag. |
| `WORKING_DIRECTORY` | `.` | Directory holding `debian/` and `package.conf`, relative to the workspace. |

Packages land in `debs/` inside that directory.

A reusable workflow is included that fans the build out across every suite and
architecture, so a packaging repository can validate a tag with a few lines —
see [Validating a packaging repository](#validating-a-packaging-repository).
Publishing is the [pkg.haus APT archive](https://apt.pkg.haus)'s job: it builds
its packages from source itself, so nothing here uploads anywhere.

## What a packaging repository looks like

```
debian/                       # the packaging itself
package.conf                  # what to build, and how
.github/workflows/main.yml    # trigger + delegation
```

## Validating a packaging repository

`.github/workflows/main.yml` in full:

```yaml
name: Build

on:
  push:
    tags:
      - '*'
  pull_request:

permissions:
  contents: read

jobs:
  build:
    uses: pkghaus/action-debian-build/.github/workflows/build.yml@v1
    secrets: inherit
```

That builds every suite and architecture in parallel, failing loudly if any leg
does not produce a package. With the org secret `APT_DISPATCH_TOKEN` available
to the caller, a green tag build also notifies the pkg.haus archive to ingest
immediately; without the secret that final job is a no-op. Publishing is not this workflow's job - the pkg.haus
APT archive builds its packages from source itself. The trigger has to live in
the calling repository - a reusable workflow cannot declare the event that
starts it.

## package.conf

```sh
UPSTREAM=https://github.com/getzola/zola.git
VERSION=v0.23.3
TOOLCHAIN=rust
DBGSYM=0
LINTIAN=warn
```

| Key | Required | Default | Meaning |
| --- | --- | --- | --- |
| `UPSTREAM` | yes | - | Git URL of the upstream project. Any URL `git clone` accepts. |
| `VERSION` | yes | - | Tag or branch to build. Overridable from the environment for local one-off builds. |
| `TOOLCHAIN` | no | `none` | `rust` bootstraps rustup's stable toolchain; `none` relies on `debian/control`. |
| `DBGSYM` | no | `0` | Set to `1` to build and publish the automatic `-dbgsym` package. |
| `LINTIAN` | no | `warn` | `off` skips checks, `warn` reports them, `error` fails the build on an error tag. |
| `SETUP_HOOK` | no | - | Shell run after the toolchain and before the build, in the entrypoint's own shell, so `PATH` changes stick. |

The package name appears nowhere in this configuration: artifacts are named from
what `dpkg` itself emits, so there is nothing to keep in sync with
`debian/changelog`.

### Toolchains

`TOOLCHAIN=rust` exists because Debian's `rustc` trails what current Rust
upstreams require, so those builds need rustup regardless of suite. Every other
language should come from `Build-Depends` in `debian/control` - a Go or C project
needs no entry here.

It installs rustup's own distribution rather than Debian's `rustup` package,
which declares `Conflicts: cargo, rustc` and would therefore be removed again
while `apt-get build-dep` installs a `cargo:native` build dependency, silently
falling back to Debian's toolchain.

`SETUP_HOOK` covers anything else - another language runtime, an extra
repository, a pre-build fixup - without needing a change here.

### Checks

`lintian` runs on the built packages. The default reports its findings without
failing, because most packages carry pre-existing tags and a release should not
start failing because lintian gained a check. Set `LINTIAN=error` once a package
is clean, or `LINTIAN=off` to skip it.

### Debug symbols

`dh_strip` automatically splits debug symbols into a `<package>-dbgsym` package
for anything that carries them, which is why a C project produces one and a Rust
release build does not. `DBGSYM=0` passes `noautodbgsym` in `DEB_BUILD_OPTIONS`
so the package is never built, rather than built and discarded.

## Building locally

Identical to what CI runs:

```sh
docker run --rm \
    --volume "$PWD:/target" \
    --workdir /target \
    ghcr.io/pkghaus/deb-builder:trixie
```

Packages land in `debs/`, owned by whoever owns the checkout. Build a tag other
than the pinned one by passing it in:

```sh
docker run --rm --env VERSION=v0.22.1 \
    --volume "$PWD:/target" --workdir /target \
    ghcr.io/pkghaus/deb-builder:trixie
```

To try a change to `entrypoint.sh` without rebuilding the image, mount over it:

```sh
docker run --rm \
    --volume "$PWD:/target" --workdir /target \
    --volume "/path/to/entrypoint.sh:/usr/local/bin/deb-build:ro" \
    ghcr.io/pkghaus/deb-builder:trixie
```

If your working copy has loose file modes, reset `debian/` to what git records
before building. debhelper treats a config file such as `debian/docs` with the
executable bit set as an *executable* config and tries to run it:

```sh
find debian -type f ! -name rules -exec chmod 0644 {} +
```

## Images

`ghcr.io/pkghaus/deb-builder:<suite>` is a multi-arch manifest covering
`amd64` and `arm64`, published for `trixie`, `testing` and `unstable`. Each
architecture is built on a native runner, so neither is emulated. A weekly
rebuild keeps the preinstalled tooling close to the rolling suites.

The image carries the fixed build tooling only. Package-specific build
dependencies are resolved from `debian/control` at build time, which is why the
apt indexes are refreshed inside every build.

The base is a build argument, so a fork is not limited to Debian:

```sh
docker build --build-arg SUITE=noble --build-arg BASE_IMAGE=ubuntu:24.04 .
```

## Using this from another account

Nothing here is specific to one owner. Two inputs cover the cases that differ:

```yaml
jobs:
  release:
    uses: pkghaus/action-debian-build/.github/workflows/build.yml@v1
    with:
      image: ghcr.io/your-name/deb-builder
      suites: '["trixie"]'
      targets: '[{"arch":"amd64","runner":"ubuntu-24.04"}]'
```

| Input | Default | Meaning |
| --- | --- | --- |
| `image` | `ghcr.io/pkghaus/deb-builder` | Builder image, without the suite tag. |
| `suites` | `["trixie","testing","unstable"]` | Suites to build, as a JSON array. |
| `targets` | `amd64` on `ubuntu-24.04`, `arm64` on `ubuntu-24.04-arm` | Runner per architecture, as JSON objects. |

Use the published images as they are, or fork this repository, let its own
`images.yml` publish to your namespace, and point `image` at those. Producing
`arm64` packages additionally requires `Architecture` in `debian/control` to
permit it - the workflow builds on an arm64 runner, but `dpkg` decides what it
emits.

## Versioning

Pin the floating major: `@v1` always points at the newest `v1.x.y` release.
Anything that changes the calling contract (inputs, `package.conf` keys,
artifact names) is a breaking change and gets a new major. Exact tags
(`v1.0.0`) never move - pin one, or a commit SHA, where bit-for-bit
determinism matters more than fixes arriving.

Releasing:

1. Land the change on the default branch with CI green.
2. Add a `CHANGELOG.md` entry under a new version heading.
3. Tag the exact version and move the major:
   `git tag -s v1.1.0 && git tag -sf v1 && git push origin v1.1.0 && git push --force origin v1`.

## Tests

```sh
tests/run.sh                     # builds a trixie image, then runs everything
tests/run.sh builder:local       # or against an image you already have
```

The suite is hermetic - the "upstream" is a git repository created inside the
mount and cloned over `file://`, so nothing depends on a third-party host staying
up. CI runs it on every suite and architecture.

| Suite | Covers |
| --- | --- |
| `test-build.sh` | default build, artifact naming, `DBGSYM` both ways, `.buildinfo` collection, all three `LINTIAN` modes, `SETUP_HOOK` including a failing one, `VERSION` override, wrong-architecture diagnosis |
| `test-retry.sh` | transient clone failures, partial-checkout cleanup, retry exhaustion, `CLONE_ATTEMPTS` bounding |
| `test-config.sh` | missing `package.conf`, missing `UPSTREAM`/`VERSION`, unknown `TOOLCHAIN`, unknown `LINTIAN` |
| `test-yamlcheck.sh` | the YAML gate accepts the workflows and rejects a duplicate key |

Clone failures are driven by a `git` shim (`tests/fake-git`) rather than by
timing, so the retry tests are deterministic rather than racing a real host.

CI additionally exercises `action.yml` itself against the fixture on every
suite, so the action's own contract is covered rather than only the entrypoint's.

Alongside those, CI runs `shellcheck`, `actionlint`, and a YAML check that
rejects duplicate mapping keys - which GitHub rejects at parse time but
`yaml.safe_load` accepts silently.

## Security

Actions are pinned to commit SHAs, checkouts carry no credentials into the build
container, and published images carry provenance and an SBOM. See
[SECURITY.md](SECURITY.md) for the trust boundaries and how to verify an image.

## License

```
Copyright 2026 pkg.haus

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

## Buy us a coffee?

If you feel like buying us a coffee (or a beer?), donations are welcome:

```
BTC : bc1qq04jnuqqavpccfptmddqjkg7cuspy3new4sxq9
DOGE: DRBkryyau5CMxpBzVmrBAjK6dVdMZSBsuS
ETH : 0x2238A11856428b72E80D70Be8666729497059d95
LTC : MQwXsBrArLRHQzwQZAjJPNrxGS1uNDDKX6
```
