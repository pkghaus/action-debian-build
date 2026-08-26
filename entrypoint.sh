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

    : "${UPSTREAM:?package.conf must set UPSTREAM}"
    : "${VERSION:?package.conf must set VERSION, or pass it in the environment}"
    TOOLCHAIN="${TOOLCHAIN:-none}"
    DBGSYM="${DBGSYM:-0}"
    LINTIAN="${LINTIAN:-warn}"
    SETUP_HOOK="${SETUP_HOOK:-}"
    SOURCE_DIR="${SOURCE_DIR:-$(basename "${UPSTREAM%.git}")}"

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
        echo "FATAL: no source directory could be derived from UPSTREAM=$UPSTREAM" >&2
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
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
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
    local attempt delay
    cd "$(mktemp -d)"
    attempt=1
    delay=2

    while true; do
        # A cancelled fetch leaves a partial tree behind, so a bare retry would
        # fail on "directory exists" rather than retrying the clone. GitHub
        # cancels HTTP/2 streams when several builds clone the same repo at
        # once, which is exactly when this loop earns its keep.
        rm -rf "$SOURCE_DIR"

        if git clone --branch "$VERSION" -- "$UPSTREAM" "$SOURCE_DIR"; then
            break
        fi

        if [ "$attempt" -ge "$CLONE_ATTEMPTS" ]; then
            echo "FATAL: cloning $UPSTREAM at $VERSION failed after $CLONE_ATTEMPTS attempts" >&2
            return 1
        fi

        echo "clone attempt $attempt/$CLONE_ATTEMPTS failed; retrying in ${delay}s" >&2
        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done

    cd "$SOURCE_DIR"
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

build() {
    # Some upstreams ship a debian/ of their own. Without this, cp would nest
    # ours inside theirs as debian/debian and the build would use theirs.
    rm -rf debian
    cp -a "$TARGET/debian" .

    # Reads Build-Depends straight from the debian/ just copied in. Preferred
    # over devscripts' mk-build-deps because it needs no extra packages in the
    # image and no `yes |` pipe, while producing an identical package.
    apply_version_qualifier

    apt-get build-dep -y ./

    # The standard entry point rather than calling debian/rules directly: it
    # runs dpkg-source --before-build, then the clean, build and binary targets
    # in order, and emits a .buildinfo recording the environment it used. Doing
    # this by hand meant reimplementing part of it and needing a separate flag
    # for packages whose build target must run before binary.
    # The failure is caught to add the hint: when a package has not been built
    # for this architecture before, dpkg-buildpackage reports it as a
    # dpkg-genbuildinfo subprocess failure, which says nothing about why.
    if ! dpkg-buildpackage --build=binary --no-sign; then
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
    for artefact in ../*.deb ../*.buildinfo; do
        name="$(basename "$artefact")"

        install -o "$uid" -g "$gid" -m 0644 "$artefact" "$dest/$name"

        case "$artefact" in
            *.deb) collected=$((collected + 1)) ;;
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

main() {
    load_config
    dependencies
    get_sources
    build
    collect
    check
}

main
