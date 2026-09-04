#!/usr/bin/env bash
#
# Canonical Debian package build for action-debian-build.
#
# Runs inside ghcr.io/<owner>/deb-builder:<suite> with a packaging repo
# mounted at /target. Configuration comes from /target/package.conf; VERSION may
# be overridden from the environment to build a tag other than the pinned one.
#
# Artifacts land in /target/debs/ owned by whoever owns the mount, under their
# canonical Debian names. The version carries a suite qualifier (~haus13+1 for a
# released suite, ~testing1 for testing, none for unstable) so that one archive
# can pool all three without two different binaries claiming one version.

set -euxo pipefail
# Without this, set -e stops at the edge of a command substitution: a function
# called as x="$(f)" keeps running after a failure instead of aborting.
shopt -s inherit_errexit

TARGET="${TARGET:-$(pwd)}"
CLONE_ATTEMPTS="${CLONE_ATTEMPTS:-5}"

# Run a command until it succeeds, with the attempt budget and doubling
# backoff the clone has always had. Every network fetch in this file gets the
# same treatment: the clone retries because GitHub cancels HTTP/2 streams when
# several builds clone at once, and the rustup bootstrap has the same exposure
# to a third-party host on up to 54 build legs in a fleet-wide wave.
#
# $1 labels the messages, the rest is the command. A caller needing to clean up
# between attempts passes a function, because the clear is part of the attempt.
retry() { # label command...
    local label="$1"; shift
    local attempt=1 delay=2

    while true; do
        if "$@"; then
            return 0
        fi

        if [ "$attempt" -ge "$CLONE_ATTEMPTS" ]; then
            echo "FATAL: $label failed after $CLONE_ATTEMPTS attempts" >&2
            return 1
        fi

        echo "$label attempt $attempt/$CLONE_ATTEMPTS failed; retrying in ${delay}s" >&2
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

# Baked in by the Dockerfile so artifacts self-identify without the workflow
# renaming them afterwards.
: "${DEB_SUITE:?the image must define DEB_SUITE}"

load_config() {
    local conf version_override
    conf="$TARGET/package.conf"

    [ -f "$conf" ] || {
        echo "FATAL: $conf not found -- is a packaging repo mounted at $TARGET?" >&2
        return 1
    }

    # Captured before sourcing so an explicit VERSION from the environment wins
    # over the pinned one. This is the only override the old build.sh -v offered
    # and the only one anything uses.
    version_override="${VERSION:-}"

    # shellcheck source=/dev/null
    . "$conf"

    # Deliberately an if rather than `[ -n ... ] && VERSION=...`: the && form
    # evaluates to false when there is no override, which would make this
    # function return non-zero the moment it became the last statement.
    if [ -n "$version_override" ]; then
        VERSION="$version_override"
    fi

    # A native package is its own upstream: there is no release feed to track
    # and no tag to clone, so UPSTREAM and VERSION describe nothing. Everything
    # the package is made of already sits in the packaging directory. The same
    # test on the same file gates the bump automation in pkghaus/packages
    # (is_native in plan-bumps.sh and bump-upstream.sh), so a package is native
    # in one place and native everywhere.
    #
    # Read from the packaging directory rather than a clone that may not happen.
    NATIVE=0
    case "$(cat "$TARGET/debian/source/format" 2>/dev/null)" in
        *native*) NATIVE=1 ;;
    esac

    if [ "$NATIVE" -eq 1 ]; then
        # Refused rather than ignored. Both were meaningful before the source
        # moved in-tree, so a leftover value is likelier to be a stale
        # package.conf than an intention, and silently ignoring it would build
        # something other than what the file appears to ask for.
        [ -z "${UPSTREAM:-}" ] || {
            echo "FATAL: $TARGET is a native package and must not set UPSTREAM" >&2
            return 1
        }
        [ -z "${VERSION:-}" ] || {
            echo "FATAL: $TARGET is a native package and must not set VERSION" >&2
            return 1
        }
    else
        : "${UPSTREAM:?package.conf must set UPSTREAM}"
        : "${VERSION:?package.conf must set VERSION, or pass it in the environment}"
    fi

    TOOLCHAIN="${TOOLCHAIN:-none}"
    DBGSYM="${DBGSYM:-0}"
    LINTIAN="${LINTIAN:-warn}"
    SETUP_HOOK="${SETUP_HOOK:-}"

    # With no UPSTREAM to take a basename from, the changelog's source name is
    # the authority -- and it is the better name anyway: the old derivation gave
    # the keyring a source tree called archive-keyring/, after the repository
    # rather than after the package.
    if [ -n "${UPSTREAM:-}" ]; then
        SOURCE_DIR="${SOURCE_DIR:-$(basename "${UPSTREAM%.git}")}"
    else
        SOURCE_DIR="${SOURCE_DIR:-$(sed -n '1s/ .*//p' "$TARGET/debian/changelog" 2>/dev/null)}"
    fi

    case "$LINTIAN" in
        off | warn | error) ;;
        *)
            echo "FATAL: unknown LINTIAN '$LINTIAN' (expected 'off', 'warn' or 'error')" >&2
            return 1
            ;;
    esac

    # Normalised to 0/1 here so the check below stays a comparison against one
    # value. It used to be that comparison alone, which made every spelling
    # except a literal 1 mean off: DBGSYM=on, =yes and =true each disabled the
    # package they were written to enable, with no error and nothing in the log.
    # Words are accepted because the neighbouring knob takes them.
    case "$DBGSYM" in
        0 | off) DBGSYM=0 ;;
        1 | on)  DBGSYM=1 ;;
        *)
            echo "FATAL: unknown DBGSYM '$DBGSYM' (expected '0'/'off' or '1'/'on')" >&2
            return 1
            ;;
    esac

    # get_sources interpolates this into rm -rf, so an empty value must not
    # reach it.
    [ -n "$SOURCE_DIR" ] || {
        echo "FATAL: no source directory could be derived from UPSTREAM=${UPSTREAM:-} or debian/changelog" >&2
        return 1
    }

    # Appended rather than assigned, so an inherited value (nocheck, terse, a
    # custom parallel=) is not silently discarded.
    DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+$DEB_BUILD_OPTIONS }parallel=$(nproc)"

    # dh_strip splits debug symbols into an automatic <pkg>-dbgsym package for
    # anything carrying them, which is why C packages produce one and Rust
    # release builds (no debug info) do not. noautodbgsym stops it being built
    # at all rather than building and discarding it -- see dh_strip(1) and the
    # get_buildoption('noautodbgsym') check in /usr/bin/dh_strip.
    if [ "$DBGSYM" != 1 ]; then
        DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS noautodbgsym"
    fi

    export DEB_BUILD_OPTIONS
}

dependencies() {
    # The image ships the fixed tooling with its apt indexes cleaned, so build
    # dependency resolution needs a fresh one here.
    apt-get update

    case "$TOOLCHAIN" in
        none)
            ;;
        rust)
            # Debian's rustc trails what current Rust upstreams require, so the
            # build uses rustup's stable regardless of suite.
            #
            # Deliberately rustup's own installer rather than Debian's rustup
            # package: that package declares "Conflicts: cargo, rustc", so
            # apt-get build-dep would remove it again while installing the
            # cargo:native/rustc:native build dependencies these packages
            # declare, silently falling back to Debian's toolchain. Installing
            # into ~/.cargo sidesteps dpkg entirely and wins on PATH.
            #
            # --default-toolchain none because the package names the version,
            # not the image: upstream's rust-toolchain.toml or a
            # RUSTUP_TOOLCHAIN in debian/rules, either of which rustup resolves
            # and downloads on first use. Installing "stable" here as well
            # downloads a whole second toolchain, since rustup treats the
            # stable channel and the version it currently points at as separate
            # installs -- measured at six components twice for one build.
            #
            # A Rust package that names no version fails with "no default
            # toolchain configured" rather than silently building with whatever
            # stable is that day, which is the failure worth having.
            #
            # Prefer `Build-Depends: rustup` over this whole branch. Debian
            # ships rustup in trixie and sid, its shims are /usr/bin/rustc and
            # /usr/bin/cargo, and it honours RUSTUP_TOOLCHAIN and
            # rust-toolchain.toml exactly as the upstream installer does. The
            # difference is that a declared build dependency lands in the
            # .buildinfo's Installed-Build-Depends, where a rebuilder can
            # resolve it from snapshot.debian.org; a toolchain curled into
            # ~/.cargo is invisible to dpkg and appears nowhere. That is the
            # same shape Go already has, golang-go as the bootstrap and the
            # exact version named in the source.
            # Fetched to a file and then run, rather than piped. A pipeline
            # cannot be retried as one command, and in a pipe the status that
            # reaches the shell is sh's, not curl's -- a truncated script can
            # leave sh reporting success on a partial install.
            _rustup_attempt() {
                local script status
                script="$(mktemp)"
                if ! curl --proto '=https' --tlsv1.2 -sSf --max-time 120 \
                    -o "$script" https://sh.rustup.rs; then
                    rm -f "$script"
                    return 1
                fi
                # No `-s --` here: those told sh to read the script from
                # stdin, which is the pipe form. With a file, everything after
                # it is passed to the script, so `-s` reached rustup-init and
                # it exited with "unexpected argument '-s' found".
                sh "$script" -y --default-toolchain none
                status=$?
                rm -f "$script"
                return "$status"
            }
            retry "fetching the rustup installer" _rustup_attempt || return 1
            # shellcheck source=/dev/null
            . "$HOME/.cargo/env"
            ;;
        *)
            echo "FATAL: unknown TOOLCHAIN '$TOOLCHAIN' (expected 'none' or 'rust')" >&2
            return 1
            ;;
    esac

    # Escape hatch for anything TOOLCHAIN does not cover. Evaluated in this
    # shell rather than a subshell, so a hook that puts a toolchain on PATH
    # affects the build the way the rust case above does.
    if [ -n "$SETUP_HOOK" ]; then
        eval "$SETUP_HOOK"
    fi
}

get_sources() {

    # /build rather than a mktemp directory, because the path is published now:
    # dpkg writes Build-Path into the .buildinfo, debrebuild rebuilds at exactly
    # that path, and a random /tmp/tmp.XXXXXXXXXX tells a reader nothing while
    # differing on every leg. /build is also the prefix dpkg accepts without
    # --always-include-path, and what Debian's own buildds use.
    mkdir -p /build
    cd /build

    # No upstream to clone: the packaging directory IS the source. Copied rather
    # than built in place, so the build still happens at /build/<source> like
    # every other package -- Build-Path keeps the same shape on every leg, and
    # the workdir the runner mounted is left untouched.
    #
    # debian/ is excluded because the overlay later is its single source, and
    # copying it here would make two. package.conf is build configuration rather
    # than source, and no other package's source package carries one. debs/ is
    # output from a previous local run.
    if [ -z "${UPSTREAM:-}" ]; then
        rm -rf "$SOURCE_DIR"
        mkdir -p "$SOURCE_DIR"
        tar -C "$TARGET" \
            --exclude=./debian --exclude=./debs --exclude=./package.conf \
            -cf - . | tar -C "$SOURCE_DIR" -xf -
        cd "$SOURCE_DIR"
        UPSTREAM_COMMIT=""
        printf 'upstream: none (native); source taken from %s\n' "$TARGET" >&2
        return 0
    fi

    # A cancelled fetch leaves a partial tree behind, so a bare retry would
    # fail on "directory exists" rather than retrying the clone. GitHub cancels
    # HTTP/2 streams when several builds clone the same repo at once, which is
    # exactly when this earns its keep. The clear belongs to the attempt, which
    # is why this is a function and not the clone alone.
    _clone_attempt() {
        rm -rf "$SOURCE_DIR"
        git clone --branch "$VERSION" -- "$UPSTREAM" "$SOURCE_DIR"
    }
    retry "cloning $UPSTREAM at $VERSION" _clone_attempt || return 1

    cd "$SOURCE_DIR"

    # What the ref actually resolved to. VERSION names a git tag, and a tag is
    # mutable: upstream can move v1.2.3 onto different code and every later
    # build silently produces different bytes under the same version. The commit
    # is content-addressed and cannot move, so it is the only durable answer to
    # "which source produced this package".
    #
    # SLSA models the same split -- the ref goes in externalParameters, the
    # resolved commit in resolvedDependencies as digest.gitCommit -- and Debian
    # has no equivalent: DEP-12 records a Repository URL with no revision, and
    # Vcs-* in debian/control describes the packaging repository, not upstream.
    UPSTREAM_COMMIT="$(git rev-parse HEAD)"
    printf 'upstream: %s %s -> %s\n' "$UPSTREAM" "$VERSION" "$UPSTREAM_COMMIT" >&2

    # The commit is the only thing the build needs from git, and it is captured
    # above. What remains is a build tree that does not match the one a rebuild
    # gets, because a source package cannot carry .git -- and Go notices.
    # `go build` stamps vcs.revision, vcs.time and vcs.modified into
    # .go.buildinfo whenever a repository is present, so every Go package built
    # here embedded metadata that nobody rebuilding from the .dsc could
    # reproduce. Measured on croc: 160 bytes of difference, and the only
    # difference, between our binary and debrebuild's.
    #
    # Deleting it rather than passing -buildvcs=false, because the flag fixes
    # one language's symptom while the tree shape is the cause.
    rm -rf .git
}

version_qualifier() {
    local id

    # Shaped after Debian's backports convention (~bpo<N>+1) but with our own
    # token, the way Debian FastTrack uses ~fto<N>+1: ~bpo belongs to official
    # backports, and squatting it invites a same-version-different-binary
    # collision if an official backport of the same package ever ships. The
    # release NUMBER rather than the codename, because codenames sort
    # alphabetically: ~bullseye1 would outrank ~bookworm1 despite bullseye
    # being older.
    case "$DEB_SUITE" in
        unstable | sid)
            # Carries the plain version, as sid does in Debian.
            ;;
        testing)
            # Invented: Debian has no convention here, because it never rebuilds
            # for testing -- the unstable binary migrates instead. This sorts
            # above every ~haus<N>+1 and below the plain version, and keeps
            # doing so after the current testing is released.
            printf '~testing1'
            ;;
        *)
            # A released suite: take its number from the image itself. testing
            # and unstable images cannot be told apart from inside (both report
            # forky/sid with no VERSION_ID), which is why the suite comes from
            # DEB_SUITE and only the number comes from os-release.
            # Not part of this repository and not present in the linter's
            # own image, so shellcheck is told not to try to follow it.
            # shellcheck source=/dev/null
            id="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"

            [ -n "$id" ] || {
                echo "FATAL: /etc/os-release has no VERSION_ID, so no release number is available for suite '$DEB_SUITE'" >&2
                return 1
            }

            printf '~haus%s+1' "$id"
            ;;
    esac
}

apply_version_qualifier() {
    local qualifier base new got

    qualifier="$(version_qualifier)"
    [ -n "$qualifier" ] || return 0

    base="$(dpkg-parsechangelog -l debian/changelog -S Version)"
    new="${base}${qualifier}"

    # The top entry's version is rewritten rather than a new entry prepended:
    # this is a rebuild of one source for another suite, and inventing changelog
    # prose to say so would be worse than letting the version say it. awk avoids
    # having to escape versions containing + or ~.
    awk -v new="$new" 'NR == 1 { sub(/\([^)]*\)/, "(" new ")") } 1' \
        debian/changelog > debian/changelog.qualified
    mv debian/changelog.qualified debian/changelog

    got="$(dpkg-parsechangelog -l debian/changelog -S Version)"
    [ "$got" = "$new" ] || {
        echo "FATAL: version qualifier did not apply (wanted $new, changelog says $got)" >&2
        return 1
    }
}

# dpkg-source clamps mtimes to SOURCE_DATE_EPOCH: anything newer is pulled down
# to it, anything OLDER is left alone. So a debian/ carrying a stale timestamp
# produces a different .debian.tar.xz from an otherwise identical build leg,
# and the two legs then disagree about the checksum their own .dsc records.
#
# Nothing in the normal path can trigger it -- git clone and actions/checkout
# both stamp current time, which is always newer than a changelog date. A cache
# restore, an artifact download, or a tar -x that preserves timestamps would.
assert_debian_mtimes() {
    local stale

    # Negated match rather than -newermt ... -prune -o -print: debian/ itself is
    # newer than the changelog, so -prune would fire on the top directory and
    # stop the descent before reaching a single file. The guard passed on a tree
    # it should have rejected until a test caught it.
    stale="$(find debian ! -newermt "@$SOURCE_DATE_EPOCH" -print)"

    [ -z "$stale" ] || {
        echo "FATAL: these files under debian/ predate the changelog entry" >&2
        echo "       (@$SOURCE_DATE_EPOCH). dpkg-source would preserve their" >&2
        echo "       timestamps and this leg's source package would not match" >&2
        echo "       the others'." >&2
        printf '%s\n' "$stale" | sed 's/^/  /' >&2
        return 1
    }
}

# A 3.0 (quilt) package needs its upstream tarball to already exist -- dpkg-source
# will not invent one, and what we have is a git checkout. Every field that
# varies between machines is pinned: --sort=name fixes entry order, --mtime the
# timestamps, --owner/--group/--numeric-owner the ownership.
#
# This is deliberately stronger than dpkg-source's clamp, which only lowers
# mtimes that are too new. Setting them unconditionally means even a tree with
# stale timestamps yields the same bytes.
#
# The tarball is shared by all three suites -- the qualifier lands on the Debian
# revision, so 11.3.6-1 and 11.3.6-1~haus13+1 have the same upstream version --
# so it must not vary by builder image either. Verified byte-identical across
# amd64 and arm64, 2 to 32 cores, different build paths, two independent clones,
# and all three images (whose gzip versions differ).
make_orig_tarball() {
    local format source upstream tarball

    format="$(cat debian/source/format 2>/dev/null || true)"
    case "$format" in
        *native*)
            # No upstream tarball exists for a native package by definition.
            return 0
            ;;
    esac

    source="$(dpkg-parsechangelog -l debian/changelog -S Source)"
    upstream="$(dpkg-parsechangelog -l debian/changelog -S Version)"
    # Everything before the last hyphen, which is how dpkg splits it too.
    upstream="${upstream%-*}"
    tarball="../${source}_${upstream}.orig.tar.gz"

    # gzip stores an mtime for the file it compresses, but reads a pipe here and
    # so records none. That is what keeps -z deterministic; do not replace this
    # with a two-step tar-then-gzip on a real file.
    tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner \
        --exclude=./debian --exclude=./.git \
        -czf "$tarball" .

    printf 'orig tarball: %s\n' "$(basename "$tarball")" >&2
}

# The compiler that ran, which is not always the one that was installed: rustup
# installs current stable and then honours a rust-toolchain.toml, and Go's
# GOTOOLCHAIN follows go.mod. Both resolve against the working directory, so
# this must be called from inside the source tree -- reading them from $HOME
# reports the bootstrap and pins the wrong version.
resolved_toolchains() {
    local pin version

    if command -v rustc >/dev/null 2>&1; then
        # Where upstream ships no rust-toolchain.toml the version is pinned in
        # debian/rules, and `export` there reaches make's recipes rather than
        # this shell. With no default toolchain installed the rustup shim has
        # nothing to resolve from here, so it must be asked for. Asked of make
        # rather than read out of the file, because make is what evaluates it;
        # an explicit target from --eval beats the catch-all pattern rule these
        # files all have, so nothing is built.
        # $(RUSTUP_TOOLCHAIN) is make's expansion, not the shell's, so the
        # single quotes are the point.
        # shellcheck disable=SC2016
        pin="$(make -f debian/rules \
            --eval='__pkghaus_toolchain: ; @printf %s "$(RUSTUP_TOOLCHAIN)"' \
            __pkghaus_toolchain 2>/dev/null || true)"

        if [ -n "$pin" ]; then
            version="$(RUSTUP_TOOLCHAIN="$pin" rustc --version 2>/dev/null || true)"
        else
            version="$(rustc --version 2>/dev/null || true)"
        fi

        # Nothing rather than "unknown": the line is a claim about what built
        # the package, and a placeholder is a worse answer than its absence.
        [ -z "$version" ] || printf 'Rustc: %s\n' "$version"
    fi

    if command -v go >/dev/null 2>&1; then
        version="$(go version 2>/dev/null || true)"
        [ -z "$version" ] || printf 'Go: %s\n' "$version"
    fi
}

build() {
    # Some upstreams ship a debian/ of their own. Without this, cp would nest
    # ours inside theirs as debian/debian and the build would use theirs.
    rm -rf debian
    cp -a "$TARGET/debian" .

    # The upstream revision, written where the source package can carry it.
    #
    # The clone's .git is removed before the build, because a source package
    # cannot contain one and anything that reads it would make our build differ
    # from a rebuild of our own .dsc. That is correct and it is what makes Go
    # binaries reproducible -- but three packages were reading it for their
    # version string and quietly lost it: berry's configure fell back to a stale
    # hardcoded 0.1.7, vergen emitted its placeholder into viddy, and vegeta's
    # own rules ran `git rev-parse HEAD` against a tree with no .git.
    #
    # An environment variable cannot fix that: dpkg records only
    # DEB_BUILD_OPTIONS and SOURCE_DATE_EPOCH in the .buildinfo's Environment,
    # so a rebuilder would not replay it and the rebuild would differ. Inside
    # debian/ it travels in the .dsc, which is the same move that pins the Rust
    # toolchain. It also answers a question `apt-get source` could not: which
    # upstream commit this source was taken from.
    #
    # Before assert_debian_mtimes, so a file written now is newer than
    # SOURCE_DATE_EPOCH rather than tripping the guard.
    if [ -n "${UPSTREAM_COMMIT:-}" ]; then
        printf '%s\n' "$UPSTREAM_COMMIT" > debian/upstream-commit
    fi

    # Reads Build-Depends straight from the debian/ just copied in. Preferred
    # over devscripts' mk-build-deps because it needs no extra packages in the
    # image and no `yes |` pipe, while producing an identical package.
    apply_version_qualifier

    # After the qualifier, so the timestamp is the one dpkg-source will use.
    SOURCE_DATE_EPOCH="$(dpkg-parsechangelog -l debian/changelog -S Timestamp)"
    export SOURCE_DATE_EPOCH

    assert_debian_mtimes
    make_orig_tarball

    apt-get build-dep -y ./

    # TOOLCHAIN=rust curls a toolchain into ~/.cargo, which wins on PATH over
    # the shims a declared `Build-Depends: rustup` installs. Both at once means
    # the build uses the invisible one while the .buildinfo names the other --
    # the exact misrecording declaring rustup is meant to end.
    if [ "$TOOLCHAIN" = rust ] && dpkg -S /usr/bin/rustc >/dev/null 2>&1; then
        echo "FATAL: this package declares a Rust toolchain as a build dependency" >&2
        echo "       and also sets TOOLCHAIN=rust. Drop TOOLCHAIN=rust: the" >&2
        echo "       declared one is recorded in the .buildinfo, the curled one" >&2
        echo "       is not, and the curled one is what would build." >&2
        return 1
    fi

    # The standard entry point rather than calling debian/rules directly: it
    # runs dpkg-source --before-build, then the clean, build and binary targets
    # in order, and emits a .buildinfo recording the environment it used. Doing
    # this by hand meant reimplementing part of it and needing a separate flag
    # for packages whose build target must run before binary.
    # The failure is caught to add the hint: when a package has not been built
    # for this architecture before, dpkg-buildpackage reports it as a
    # dpkg-genbuildinfo subprocess failure, which says nothing about why.
    # --build=full rather than binary: it additionally produces the .dsc and the
    # two source tarballs, which is what lets debrebuild verify these packages.
    # Given a .buildinfo alone it resolves the whole environment from
    # snapshot.debian.org and then stops, because the source package was never
    # in Debian and debsnap cannot find it. A .dsc sitting beside the record is
    # the entire fix -- debrebuild prefers a local one and never calls debsnap.
    #
    # --always-include-path because dpkg writes Build-Path only when the build
    # directory starts with /build/, and debrebuild's mmdebstrap builder calls
    # dirname() on that field unconditionally: without it the rebuild dies with
    # "fileparse(): need a valid pathname". --no-respect-build-path does not
    # help, it sets the same variable to undef.
    if ! dpkg-buildpackage --build=full --no-sign \
        --buildinfo-option=--always-include-path; then
        echo "FATAL: dpkg-buildpackage failed." >&2
        echo "  Does Architecture in debian/control permit $(dpkg --print-architecture)?" >&2
        return 1
    fi
}

collect() {
    local dest uid gid artefact name collected
    dest="$TARGET/debs"
    uid="$(stat --printf %u "$TARGET")"
    gid="$(stat --printf %g "$TARGET")"
    collected=0

    # Owned by the mount owner, not root: a root-owned debs/ in someone's
    # working copy needs root to clean up again.
    install -d -o "$uid" -g "$gid" "$dest"

    # Without nullglob an unmatched glob is passed through literally, and the
    # build failing to produce anything would surface as
    # "install: cannot stat '../*.deb'" instead of the message below.
    shopt -s nullglob

    # Canonical Debian names, unaltered: the suite-qualified version already
    # makes them unique across suites, so there is nothing left to disambiguate.
    # .changes is not collected -- the archive ingests .deb files directly.
    # The source package travels with the binaries: debrebuild looks for the
    # .dsc in the same directory as the .buildinfo, so publishing them together
    # is what makes a record actionable rather than merely readable.
    # *.tar.* rather than the two quilt names: a native package's source is a
    # single <source>_<version>.tar.xz, and collecting the .dsc without it would
    # publish a source package that cannot be unpacked.
    for artefact in ../*.deb ../*.buildinfo ../*.dsc ../*.tar.*; do
        name="$(basename "$artefact")"

        install -o "$uid" -g "$gid" -m 0644 "$artefact" "$dest/$name"

        case "$artefact" in
            *.deb) collected=$((collected + 1)) ;;
            # A sidecar sharing the buildinfo's stem, so the two travel together
            # and a reader can pair them without parsing either. The buildinfo
            # records the environment a package was built in; this records the
            # source it was built from, which nothing in the .deb, the
            # .buildinfo or debian/control carries.
            #
            # The toolchain lines are provenance, not mechanism: debrebuild
            # reads only the .buildinfo and will never see this file. What makes
            # a compiler reproducible is pinning it in the source -- go.mod for
            # Go, rust-toolchain.toml or RUSTUP_TOOLCHAIN for Rust -- so that it
            # travels inside the .dsc.
            *.buildinfo)
                {
                    # A native package has no upstream to name, and saying so
                    # with empty fields would read as a failed lookup. The
                    # source package IS the source: the .dsc and the tarball
                    # beside this file are the whole answer.
                    if [ -n "${UPSTREAM:-}" ]; then
                        printf 'Repository: %s\nRef: %s\nCommit: %s\n' \
                            "$UPSTREAM" "$VERSION" "$UPSTREAM_COMMIT"
                    else
                        printf 'Repository: none (native package; the source package is the source)\n'
                    fi
                    resolved_toolchains
                } > "$dest/${name%.buildinfo}.source"
                chown "$uid:$gid" "$dest/${name%.buildinfo}.source"
                chmod 0644 "$dest/${name%.buildinfo}.source"
                ;;
        esac
    done

    shopt -u nullglob

    # An invariant rather than a guard against known input: dpkg-buildpackage
    # fails first in every case reachable so far. It stays because the
    # alternative failure mode -- succeeding with an empty debs/ -- would be
    # silent.
    if [ "$collected" -eq 0 ]; then
        echo "FATAL: no packages were produced." >&2
        return 1
    fi
}

check() {
    local dest
    dest="$TARGET/debs"

    case "$LINTIAN" in
        off)
            return 0
            ;;
        warn)
            # Reported but never fatal: most packages carry pre-existing tags,
            # and a release should not start failing because lintian gained a
            # check.
            lintian --tag-display-limit 0 "$dest"/*.deb || true
            ;;
        error)
            lintian --tag-display-limit 0 --fail-on error "$dest"/*.deb
            ;;
    esac
}

# 88% of this pipeline's runner time is inside this script, and until now it was
# one number per leg: 170 seconds for croc, 600 for zola, with no way to tell an
# image pull from a dependency install from a compile. Every optimisation past
# that was guesswork.
#
# Each phase is still called directly by main below, rather than through a
# wrapper taking the function name. A wrapper reads better and cost a green
# lint: passing these as arguments makes shellcheck lose track of who invokes
# what, and it starts reporting the retry helpers' callbacks as dead code
# (SC2329). Timing is not worth disabling a check that finds real dead code.
PHASE_TOTAL=0
phase_done() { # name start-epoch
    local elapsed
    elapsed=$(( $(date +%s) - $2 ))
    PHASE_TOTAL=$(( PHASE_TOTAL + elapsed ))
    # Printed as each phase finishes rather than as one summary at the end, so
    # a run that dies in build still reports what the phases before it cost.
    echo "==> phase $1: ${elapsed}s (cumulative ${PHASE_TOTAL}s)"
}

main() {
    local t
    t="$(date +%s)"; load_config;  phase_done load_config  "$t"
    t="$(date +%s)"; dependencies; phase_done dependencies "$t"
    t="$(date +%s)"; get_sources;  phase_done get_sources  "$t"
    t="$(date +%s)"; build;        phase_done build        "$t"
    t="$(date +%s)"; collect;      phase_done collect      "$t"
    t="$(date +%s)"; check;        phase_done check        "$t"
    echo "==> build complete in ${PHASE_TOTAL}s"
}

main
