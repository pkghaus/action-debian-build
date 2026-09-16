#!/usr/bin/env bash
#
# The working tree must carry the same mtimes as the orig tarball built from it.
#
# dpkg-deb clamps mtimes NEWER than SOURCE_DATE_EPOCH and leaves older ones
# alone, so where a packaged file's timestamp comes from decides what it is. Our
# builds clone upstream, so every file is newer than the epoch and gets clamped
# down to it; a rebuilder unpacks the orig tarball, whose stamps are upstream's
# commit date and therefore survive untouched. Any file installed by a route
# that PRESERVES its source mtime then differs between the two, and the .deb
# does not reproduce.
#
# Which route matters: dh_installexamples and dh_installchangelogs preserve,
# while install(1) and dh_installman write new files that are newer than the
# epoch either way. The fixture only installs through the Makefile's
# `install -Dm0755`, so the divergence is invisible to every other suite --
# this one adds an examples manifest to reach it.
#
# Usage: tests/test-mtime-provenance.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# What make_workdir pins the fixture's upstream commit to, and so what
# make_orig_tarball stamps into the tarball. Kept in step with lib.sh by hand:
# the two are a pair, and a mismatch fails the first assertion below rather
# than silently weakening the test.
upstream_epoch=1700000000
example=usr/share/doc/deb-build-fixture/examples/Makefile

work="$(make_workdir "$IMAGE")"
printf 'Makefile\n' > "$work/debian/deb-build-fixture.examples"
chmod 0644 "$work/debian/deb-build-fixture.examples"
run_build "$IMAGE" "$work"

deb="$(find "$work/debs" -name 'deb-build-fixture_*.deb' -print -quit)"
buildinfo="$(find "$work/debs" -name '*.buildinfo' -print -quit)"
orig="$work/debs/deb-build-fixture_0.0.1.orig.tar.gz"

if [ -z "$deb" ] || [ -z "$buildinfo" ]; then
    report fail "the build produced a .deb and a .buildinfo" \
        "got: $(find "$work/debs" -maxdepth 1 -printf '%f ' 2>/dev/null); log: $BUILD_LOG"
    rm -rf "$work"
    summary 4
fi
report pass "the build produced a .deb and a .buildinfo"

# The epoch a rebuilder inherits, read from the record rather than recomputed
# from the changelog, so this tests what the build actually used.
source_date_epoch="$(sed -n 's/^ *SOURCE_DATE_EPOCH="\([0-9]*\)".*/\1/p' "$buildinfo")"

# Everything below is only a test while these two differ. Equal epochs make the
# clamp a no-op and all three assertions pass on the unfixed entrypoint.
if [ -n "$source_date_epoch" ] && [ "$source_date_epoch" -gt "$upstream_epoch" ]; then
    report pass "the changelog postdates the upstream commit"
else
    report fail "the changelog postdates the upstream commit" \
        "SOURCE_DATE_EPOCH=${source_date_epoch:-<absent>} upstream=$upstream_epoch"
fi

# tar reports member mtimes in the timezone it is run in, so pin it to UTC and
# convert, rather than parsing a local-time string.
tarball_mtime="$(docker run --rm --volume "$work/debs:/t:ro" --entrypoint sh "$IMAGE" -c '
    TZ=UTC tar --full-time -tvzf /t/deb-build-fixture_0.0.1.orig.tar.gz ./Makefile \
    | awk "{print \$4\" \"\$5}"' 2>/dev/null | { read -r d t; date -u -d "$d $t" +%s 2>/dev/null; } || true)"

if [ "$tarball_mtime" = "$upstream_epoch" ]; then
    report pass "the orig tarball stamps upstream's commit date"
else
    report fail "the orig tarball stamps upstream's commit date" \
        "got: ${tarball_mtime:-<unreadable>}, want $upstream_epoch ($orig)"
fi

# THE REGRESSION. Without the touch that follows the tar in make_orig_tarball,
# this file is the clone's -- newer than the epoch, so dpkg-deb clamps it to
# SOURCE_DATE_EPOCH -- while a rebuilder's copy comes out of the tarball above
# at upstream's commit date and is left alone. Same bytes, different timestamp,
# different .deb.
packaged_mtime="$(docker run --rm --volume "$work/debs:/t:ro" --entrypoint sh "$IMAGE" -c "
    set -e
    dpkg-deb --fsys-tarfile /t/$(basename "$deb") \
    | tar -C /tmp -xf - ./$example
    stat -c %Y /tmp/$example" 2>/dev/null || true)"

if [ "$packaged_mtime" = "$tarball_mtime" ]; then
    report pass "an mtime-preserving install matches the orig tarball"
else
    report fail "an mtime-preserving install matches the orig tarball" \
        "packaged=${packaged_mtime:-<unreadable>} tarball=${tarball_mtime:-<unreadable>}; log: $BUILD_LOG"
fi

# The other half of the same decision: debian/ is pruned from that touch on
# purpose. Those files reach the .debian.tar through dpkg-source, which clamps
# them to SOURCE_DATE_EPOCH from both paths, so moving them back to the older
# upstream epoch would make them survive the clamp and create the divergence
# this fix closes. Nothing else guards the prune -- assert_debian_mtimes runs
# BEFORE make_orig_tarball, so it cannot see a restamp that happens after it.
debian_mtime="$(docker run --rm --volume "$work/debs:/t:ro" --entrypoint sh "$IMAGE" -c '
    TZ=UTC tar --full-time -tvJf /t/deb-build-fixture_*.debian.tar.xz debian/changelog \
    | awk "{print \$4\" \"\$5}"' 2>/dev/null | { read -r d t; date -u -d "$d $t" +%s 2>/dev/null; } || true)"

if [ "$debian_mtime" = "$source_date_epoch" ]; then
    report pass "debian/ is left on the changelog's clock"
else
    report fail "debian/ is left on the changelog's clock" \
        "got: ${debian_mtime:-<unreadable>}, want $source_date_epoch"
fi

rm -rf "$work"

summary 5
