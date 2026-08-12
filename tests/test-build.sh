#!/usr/bin/env bash
#
# Covers the build variants selected by package.conf: the default path, debug
# symbol packages, and packages that need debian/rules build before binary.
#
# Usage: tests/test-build.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

suite="$(docker run --rm --entrypoint sh "$IMAGE" -c 'printf %s "$DEB_SUITE"')"
arch="$(docker run --rm --entrypoint sh "$IMAGE" -c 'dpkg --print-architecture')"

# Mirror of the entrypoint's version_qualifier(), so the assertions below state
# the full expected filename rather than pattern-matching around it.
case "$suite" in
    unstable | sid) qualifier="" ;;
    testing)        qualifier="~testing1" ;;
    *)              qualifier="~haus$(docker run --rm --entrypoint sh "$IMAGE" \
                        -c '. /etc/os-release && printf %s "$VERSION_ID"')+1" ;;
esac

# --- default: one package, correctly named, containing the built binary ------
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -eq 0 ] && [ "$(count_debs "$work")" -eq 1 ]; then
    report pass "default build produces exactly one package"
else
    report fail "default build produces exactly one package" \
        "status=$BUILD_STATUS debs=$(count_debs "$work"); log: $BUILD_LOG"
fi

expected="deb-build-fixture_0.0.1-1${qualifier}_${arch}.deb"
if [ -f "$work/debs/$expected" ]; then
    report pass "the artifact carries the suite-qualified version: $expected"
else
    report fail "the artifact carries the suite-qualified version" \
        "expected $expected, got: $(debs_in "$work" | xargs -r -n1 basename | tr '\n' ' ')"
fi

if docker run --rm --volume "$work/debs:/t:ro" --entrypoint sh "$IMAGE" -c "
        dpkg-deb -c '/t/$expected' | grep -q 'usr/bin/deb-build-fixture'"; then
    report pass "the package contains the compiled binary"
else
    report fail "the package contains the compiled binary"
fi

rm -rf "$work"

# --- DBGSYM=1 additionally produces the automatic debug package -------------
work="$(make_workdir "$IMAGE")"
printf 'DBGSYM=1\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -eq 0 ] && [ "$(count_debs "$work")" -eq 2 ]; then
    report pass "DBGSYM=1 produces a debug package"
else
    report fail "DBGSYM=1 produces a debug package" \
        "status=$BUILD_STATUS debs=$(count_debs "$work"); log: $BUILD_LOG"
fi

if debs_in "$work" | grep -q -- '-dbgsym_'; then
    report pass "the debug package is named -dbgsym"
else
    report fail "the debug package is named -dbgsym" \
        "got: $(debs_in "$work" | xargs -r -n1 basename | tr '\n' ' ')"
fi

rm -rf "$work"

# --- the default really is off, not merely unset -----------------------------
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work"

if ! debs_in "$work" | grep -q -- '-dbgsym_'; then
    report pass "debug packages are off by default"
else
    report fail "debug packages are off by default"
fi

if grep -q 'noautodbgsym' "$BUILD_LOG"; then
    report pass "the default passes noautodbgsym to the build"
else
    report fail "the default passes noautodbgsym to the build" "log: $BUILD_LOG"
fi

rm -rf "$work"

# --- .buildinfo rides along with the package --------------------------------
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work"

if find "$work/debs" -name '*.buildinfo' | grep -q .; then
    report pass "a .buildinfo is collected next to the package"
else
    report fail "a .buildinfo is collected next to the package" \
        "got: $(find "$work/debs" -type f -printf '%f ')"
fi

# It records the environment the package was built in, so it has to name the
# suite's own packages rather than be an empty stub.
if grep -q 'Installed-Build-Depends' "$(find "$work/debs" -name '*.buildinfo' | head -1)"; then
    report pass "the .buildinfo records the build environment"
else
    report fail "the .buildinfo records the build environment"
fi

# .changes is produced by dpkg-buildpackage but deliberately not collected: the
# suite suffix would invalidate the filenames it lists.
if ! find "$work/debs" -name '*.changes' | grep -q .; then
    report pass ".changes is not collected"
else
    report fail ".changes is not collected"
fi

rm -rf "$work"

# --- lintian: off is silent, warn reports without failing --------------------
work="$(make_workdir "$IMAGE")"
printf 'LINTIAN=off\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -eq 0 ] && ! grep -qE '^(E|W|I): deb-build-fixture' "$BUILD_LOG"; then
    report pass "LINTIAN=off runs no checks"
else
    report fail "LINTIAN=off runs no checks" "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work"

if grep -q 'lintian --tag-display-limit' "$BUILD_LOG"; then
    report pass "lintian runs by default"
else
    report fail "lintian runs by default" "log: $BUILD_LOG"
fi

if [ "$BUILD_STATUS" -eq 0 ]; then
    report pass "the default lintian mode cannot fail a build"
else
    report fail "the default lintian mode cannot fail a build" "log: $BUILD_LOG"
fi

rm -rf "$work"

# --- SETUP_HOOK runs in the entrypoint's own shell ---------------------------
work="$(make_workdir "$IMAGE")"
printf 'SETUP_HOOK="echo hook-sentinel-ran"\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -eq 0 ] && grep -q 'hook-sentinel-ran' "$BUILD_LOG"; then
    report pass "SETUP_HOOK is executed"
else
    report fail "SETUP_HOOK is executed" "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

# A hook that fails must stop the build rather than being ignored.
work="$(make_workdir "$IMAGE")"
printf 'SETUP_HOOK="exit 3"\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && [ "$(count_debs "$work")" -eq 0 ]; then
    report pass "a failing SETUP_HOOK fails the build"
else
    report fail "a failing SETUP_HOOK fails the build" \
        "status=$BUILD_STATUS debs=$(count_debs "$work")"
fi

rm -rf "$work"

# --- a build that produces nothing says so, and says why ---------------------
# The likely real cause is an arch mismatch: building on arm64 with a
# debian/control that only permits amd64. A foreign architecture reproduces it
# deterministically on any host.
work="$(make_workdir "$IMAGE")"
sed -i 's/^Architecture: any$/Architecture: hurd-i386/' "$work/debian/control"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'dpkg-buildpackage failed' "$BUILD_LOG"; then
    report pass "a build for the wrong architecture fails with a diagnosis"
else
    report fail "a build for the wrong architecture fails with a diagnosis" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

if grep -q 'Does Architecture in debian/control permit' "$BUILD_LOG"; then
    report pass "the diagnosis names the architecture to check"
else
    report fail "the diagnosis names the architecture to check" "log: $BUILD_LOG"
fi

rm -rf "$work"

# --- VERSION from the environment overrides package.conf ---------------------
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work" --env VERSION=no-such-tag

if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'no-such-tag' "$BUILD_LOG"; then
    report pass "VERSION from the environment wins over package.conf"
else
    report fail "VERSION from the environment wins over package.conf" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

summary
