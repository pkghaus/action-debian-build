#!/usr/bin/env bash
#
# Covers the source package a build now emits alongside the binaries, which is
# what makes a published .buildinfo actionable: debrebuild looks for the .dsc in
# the same directory as the record, and refuses to proceed without it.
#
# Usage: tests/test-source-package.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

suite="$(docker run --rm --entrypoint sh "$IMAGE" -c 'printf %s "$DEB_SUITE"')"

case "$suite" in
    unstable | sid) qualifier="" ;;
    testing)        qualifier="~testing1" ;;
    *)              qualifier="~haus$(docker run --rm --entrypoint sh "$IMAGE" \
                        -c '. /etc/os-release && printf %s "$VERSION_ID"')+1" ;;
esac
version="0.0.1-1${qualifier}"
native_version="0.0.1${qualifier}"

# --- native package: a .dsc and the single source tarball, no orig ----------
# Native is the minority format (one package in the fleet) so the shared fixture
# is quilt, and make_native_workdir converts it. The version loses its Debian
# revision because dpkg rejects "native package version may not have a revision"
# -- a check --build=binary never reached, and the reason the fleet's only
# native package is versioned 2026.08.15 rather than 2026.08.15-1. It also drops
# UPSTREAM, which a native package must not set; test-native.sh covers why.
work="$(make_native_workdir)"
run_build "$IMAGE" "$work"

if [ -f "$work/debs/deb-build-fixture_${native_version}.dsc" ]; then
    report pass "the build emits a .dsc"
else
    report fail "the build emits a .dsc" \
        "got: $(find "$work/debs" -maxdepth 1 -printf '%f ' 2>/dev/null); log: $BUILD_LOG"
fi

# The whole point of collecting *.tar.* rather than the two quilt names: a
# native source package is one tarball with neither "orig" nor "debian" in it,
# and a .dsc published without it cannot be unpacked.
if [ -f "$work/debs/deb-build-fixture_${native_version}.tar.xz" ]; then
    report pass "a native package's source tarball is collected"
else
    report fail "a native package's source tarball is collected" \
        "got: $(find "$work/debs" -maxdepth 1 -printf '%f ' 2>/dev/null)"
fi

if [ -z "$(find "$work/debs" -name '*.orig.tar.*' -print -quit)" ]; then
    report pass "a native package produces no orig tarball"
else
    report fail "a native package produces no orig tarball"
fi

# debrebuild verifies the .dsc against this block. An unlisted .dsc is accepted
# without any verification at all, so a record that omits it does not bind the
# source it claims to describe.
buildinfo="$(find "$work/debs" -name '*.buildinfo' -print -quit)"
if grep -q " deb-build-fixture_${native_version}.dsc\$" "$buildinfo"; then
    report pass "the buildinfo checksums its own .dsc"
else
    report fail "the buildinfo checksums its own .dsc"
fi

rm -rf "$work"

# --- the two fields debrebuild needs, on a package that has an upstream -----
# A fresh quilt workdir rather than the native one above: both fields below are
# about the upstream path, and a native package has none. They used to share a
# workdir because the native case was a quilt fixture with its format flipped,
# so UPSTREAM was still set and Build-Path still read /build/upstream. Once a
# native package stopped cloning anything, that coupling made two assertions
# about upstreams run against a package without one.
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work"
buildinfo="$(find "$work/debs" -name '*.buildinfo' -print -quit)"

# Without Build-Path, debrebuild's mmdebstrap builder dies in dirname() with
# "fileparse(): need a valid pathname". --no-respect-build-path does not help;
# it sets the same variable to undef.
if grep -qx 'Build-Path: /build/upstream' "$buildinfo"; then
    report pass "the buildinfo records a deterministic Build-Path"
else
    report fail "the buildinfo records a deterministic Build-Path" \
        "got: $(grep '^Build-Path' "$buildinfo" || echo '<absent>')"
fi

# --- the upstream revision travels inside the source package ----------------
# The clone's .git is deleted before the build, so anything that read it for a
# version string lost it. This file is how that information survives into the
# .dsc, where a rebuilder gets the same value and the build stays reproducible.
if [ -f "$work/debian/upstream-commit" ]; then
    report fail "the commit file is written into the build, not the workdir" \
        "it leaked back into $work/debian"
else
    report pass "the commit file is written into the build, not the workdir"
fi

commit_in_src="$(tar xOf "$(find "$work/debs" -name '*.debian.tar.*' -print -quit)" \
    debian/upstream-commit 2>/dev/null || true)"
if printf '%s' "$commit_in_src" | grep -q '^[0-9a-f]\{40\}$'; then
    report pass "the source package carries the upstream commit"
else
    report fail "the source package carries the upstream commit" \
        "got: '${commit_in_src}'"
fi

if [ "$commit_in_src" = "$(grep '^Commit: ' "$(find "$work/debs" -name '*.source' -print -quit)" | cut -d' ' -f2)" ]; then
    report pass "the commit in the source matches the one in .source"
else
    report fail "the commit in the source matches the one in .source"
fi

# --- .source carries the source, and no invented toolchain ------------------
source_file="$(find "$work/debs" -name '*.source' -print -quit)"

if grep -q '^Commit: [0-9a-f]\{40\}$' "$source_file"; then
    report pass ".source records the resolved upstream commit"
else
    report fail ".source records the resolved upstream commit" \
        "got: $(cat "$source_file")"
fi

# A C package in an image carrying neither rustc nor go must not claim one.
if docker run --rm --entrypoint sh "$IMAGE" -c 'command -v go rustc >/dev/null 2>&1'; then
    report pass "toolchain assertion skipped -- image ships a toolchain"
elif ! grep -qE '^(Rustc|Go):' "$source_file"; then
    report pass ".source names no toolchain when none is installed"
else
    report fail ".source names no toolchain when none is installed" \
        "got: $(cat "$source_file")"
fi

rm -rf "$work"

# --- the toolchain line reports the pin, not the shim's confusion -----------
# rustup installs with --default-toolchain none, so where a package pins its
# version in debian/rules -- which `export` puts in make's recipe environment,
# not the entrypoint's -- the shim has nothing to resolve and reported
# "Rustc: unknown". A stub compiler stands in for rustup here, echoing the
# variable it was given, which is exactly what the shim does with a real one.
work="$(make_workdir "$IMAGE")"
# After the shebang, not before it: debian/rules is executed directly, so a
# line above #!/usr/bin/make -f leaves it to be run by sh.
sed -i '1a export RUSTUP_TOOLCHAIN := 9.9.9' "$work/debian/rules"
# Single-quoted on purpose: every expansion here belongs to the shell inside
# the container, not to this one.
# shellcheck disable=SC2016
run_build "$IMAGE" "$work" --env \
    'SETUP_HOOK=mkdir -p /stub && printf "#!/bin/sh\necho rustc \$RUSTUP_TOOLCHAIN\n" > /stub/rustc && chmod 0755 /stub/rustc && PATH=/stub:$PATH && export PATH'

source_file="$(find "$work/debs" -name '*.source' -print -quit 2>/dev/null)"
if [ -n "$source_file" ] && grep -qx 'Rustc: rustc 9.9.9' "$source_file"; then
    report pass ".source reports the version pinned in debian/rules"
else
    report fail ".source reports the version pinned in debian/rules" \
        "got: $(cat "$source_file" 2>/dev/null); log: $BUILD_LOG"
fi
rm -rf "$work"

# --- quilt package: orig and debian tarballs, and a shared orig -------------
# Two builds of the same source must agree byte for byte on the orig tarball,
# because all six legs of a version publish to one key. The suite qualifier
# lands on the Debian revision, so the upstream version -- and the tarball -- is
# the same for trixie, testing and unstable.
quilt_orig=""
for run in 1 2; do
    work="$(make_workdir "$IMAGE")"
    run_build "$IMAGE" "$work"

    orig="$work/debs/deb-build-fixture_0.0.1.orig.tar.gz"
    if [ "$run" = 1 ]; then
        if [ -f "$orig" ] && [ -f "$work/debs/deb-build-fixture_${version}.debian.tar.xz" ]; then
            report pass "a quilt package produces orig and debian tarballs"
        else
            report fail "a quilt package produces orig and debian tarballs" \
                "got: $(find "$work/debs" -maxdepth 1 -printf '%f ' 2>/dev/null); log: $BUILD_LOG"
        fi
        quilt_orig="$(sha256sum "$orig" 2>/dev/null | cut -d' ' -f1)"
    else
        if [ -n "$quilt_orig" ] && [ "$quilt_orig" = "$(sha256sum "$orig" 2>/dev/null | cut -d' ' -f1)" ]; then
            report pass "the orig tarball is byte-identical across builds"
        else
            report fail "the orig tarball is byte-identical across builds" \
                "run1=$quilt_orig run2=$(sha256sum "$orig" 2>/dev/null | cut -d' ' -f1)"
        fi
    fi
    rm -rf "$work"
done

# --- no VCS metadata reaches the package -------------------------------------
# Go stamps vcs.revision, vcs.time and vcs.modified into .go.buildinfo whenever
# it finds a repository, and a source package cannot carry one. Every Go package
# built here was therefore unreproducible from its own .dsc: debrebuild's rebuild
# of croc differed from ours by 160 bytes, all of it this. The fixture is C, so
# what is asserted is the cause rather than the symptom.
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work"

if grep -q 'rm -rf .git' "$BUILD_LOG"; then
    report pass "the clone's git metadata is removed before the build"
else
    report fail "the clone's git metadata is removed before the build" \
        "log: $BUILD_LOG"
fi

# The tree dpkg-source sees must be the tree a rebuilder gets: no .git in the
# orig tarball, and none left behind for a build to notice.
if docker run --rm --volume "$work/debs:/t:ro" --entrypoint sh "$IMAGE" -c '
        tar -tzf /t/deb-build-fixture_0.0.1.orig.tar.gz | grep -q "\./\.git/"' 2>/dev/null; then
    report fail "the orig tarball carries no .git"
else
    report pass "the orig tarball carries no .git"
fi
rm -rf "$work"

# --- rustup declared and curled at once is refused ---------------------------
# The curled toolchain lands in ~/.cargo and wins on PATH; the declared one is
# what the .buildinfo names. Together they are the misrecording that declaring
# rustup exists to end, so the build stops rather than producing it.
work="$(make_workdir "$IMAGE")"
printf 'TOOLCHAIN=rust\n' >> "$work/package.conf"
sed -i 's/^ debhelper-compat (= 13),$/ debhelper-compat (= 13),\n rustup,/' "$work/debian/control"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'also sets TOOLCHAIN=rust' "$BUILD_LOG"; then
    report pass "declaring rustup and setting TOOLCHAIN=rust is refused"
else
    report fail "declaring rustup and setting TOOLCHAIN=rust is refused" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi
rm -rf "$work"

# --- the mtime guard --------------------------------------------------------
# dpkg-source clamps mtimes to SOURCE_DATE_EPOCH, so a file NEWER than the
# changelog date is normalised while an older one is preserved verbatim. Two
# legs would then disagree on .debian.tar.xz. Nothing in the normal path can
# cause it, which is exactly why it needs a guard rather than a comment.
work="$(make_workdir "$IMAGE")"
touch -d '1999-12-31 23:59:58' "$work/debian/control"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'predate the changelog entry' "$BUILD_LOG"; then
    report pass "a debian/ file older than the changelog fails the build"
else
    report fail "a debian/ file older than the changelog fails the build" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi
rm -rf "$work"

summary
