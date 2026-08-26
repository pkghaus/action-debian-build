#!/usr/bin/env bash
#
# Covers configuration validation: a misconfigured packaging repo should fail
# immediately with a message naming what is wrong, rather than part-way through
# a build with something obscure.
#
# Usage: tests/test-config.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- no package.conf at all --------------------------------------------------
work="$(make_workdir "$IMAGE")"
rm -f "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'package.conf not found' "$BUILD_LOG"; then
    report pass "a missing package.conf is reported"
else
    report fail "a missing package.conf is reported" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

# --- package.conf without UPSTREAM ------------------------------------------
work="$(make_workdir "$IMAGE")"
printf 'VERSION=v0.0.1\n' > "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'UPSTREAM' "$BUILD_LOG"; then
    report pass "a missing UPSTREAM is reported"
else
    report fail "a missing UPSTREAM is reported" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

# --- package.conf without VERSION -------------------------------------------
work="$(make_workdir "$IMAGE")"
printf 'UPSTREAM=file:///target/upstream\n' > "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'VERSION' "$BUILD_LOG"; then
    report pass "a missing VERSION is reported"
else
    report fail "a missing VERSION is reported" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

# --- an unknown lintian mode is rejected rather than silently ignored --------
work="$(make_workdir "$IMAGE")"
printf 'LINTIAN=maybe\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q "unknown LINTIAN" "$BUILD_LOG"; then
    report pass "an unknown LINTIAN mode is rejected"
else
    report fail "an unknown LINTIAN mode is rejected" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

# --- an unknown DBGSYM value is rejected rather than silently meaning off ----
# The regression this guards: the value was only ever compared against 1, so
# every other spelling disabled dbgsym instead of enabling it, silently.
work="$(make_workdir "$IMAGE")"
printf 'DBGSYM=yes\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q "unknown DBGSYM" "$BUILD_LOG"; then
    report pass "an unknown DBGSYM value is rejected"
else
    report fail "an unknown DBGSYM value is rejected" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

# --- DBGSYM accepts words as well as digits ---------------------------------
work="$(make_workdir "$IMAGE")"
printf 'DBGSYM=off\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -eq 0 ]; then
    report pass "DBGSYM=off is accepted"
else
    report fail "DBGSYM=off is accepted" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

# --- an unknown toolchain is rejected rather than silently ignored -----------
work="$(make_workdir "$IMAGE")"
printf 'TOOLCHAIN=haskell\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q "unknown TOOLCHAIN" "$BUILD_LOG"; then
    report pass "an unknown TOOLCHAIN is rejected"
else
    report fail "an unknown TOOLCHAIN is rejected" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

summary
