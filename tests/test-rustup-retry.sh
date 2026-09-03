#!/usr/bin/env bash
#
# Covers the rustup bootstrap's retry. It fetches an installer from a
# third-party host on every Rust leg -- up to 54 of them in a fleet-wide wave
# -- and had no retry at all while the git clone twenty lines below it had
# five attempts with doubling backoff. Both go through retry() now.
#
# Driven by a curl shim rather than by a real outage, so it is deterministic.
# The build is never expected to finish: reaching the toolchain bootstrap and
# failing there is the whole assertion, which also keeps this cheap.
#
# Usage: tests/test-rustup-retry.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

shim_args=(
    --volume "$TESTS_DIR/fake-curl:/usr/local/bin/curl:ro"
)

# --- the fetch is retried, and bounded by the same budget --------------------
# TOOLCHAIN=rust is what selects the bootstrap. The budget is lowered because
# the backoff doubles: a full five would spend 30s sleeping.
work="$(make_workdir "$IMAGE")"
sed -i 's/^TOOLCHAIN=.*/TOOLCHAIN=rust/' "$work/package.conf"
grep -q '^TOOLCHAIN=rust' "$work/package.conf" || {
    echo "FATAL: the fixture's package.conf did not take TOOLCHAIN=rust" >&2
    exit 1
}

run_build "$IMAGE" "$work" "${shim_args[@]}" \
    --env CURL_FAIL_TIMES=99 --env CLONE_ATTEMPTS=3

if [ "$BUILD_STATUS" -ne 0 ]; then
    report pass "an unreachable rustup.rs fails the build"
else
    report fail "an unreachable rustup.rs fails the build" "status=0; log: $BUILD_LOG"
fi

attempts="$(grep -c 'simulated rustup fetch failure' "$BUILD_LOG" || true)"
if [ "$attempts" -eq 3 ]; then
    report pass "the rustup fetch is retried up to the attempt budget"
else
    report fail "the rustup fetch is retried up to the attempt budget" \
        "counted $attempts, wanted 3; log: $BUILD_LOG"
fi

if grep -q 'fetching the rustup installer failed after 3 attempts' "$BUILD_LOG"; then
    report pass "the failure names what could not be fetched"
else
    report fail "the failure names what could not be fetched" "log: $BUILD_LOG"
fi

# Without a retry there is exactly one attempt: this is the assertion that
# would have failed before the change, and it is separate from the count above
# so a budget regression and a missing retry are told apart.
if [ "$attempts" -gt 1 ]; then
    report pass "the bootstrap does not give up after one attempt"
else
    report fail "the bootstrap does not give up after one attempt" \
        "only $attempts attempt(s); log: $BUILD_LOG"
fi

rm -rf "$work"

# --- a transient failure is retried and the bootstrap still proceeds ---------
# One failure, then the real curl. The build may still fail later for reasons
# this test does not care about, so the assertion is on the fetch succeeding.
work="$(make_workdir "$IMAGE")"
sed -i 's/^TOOLCHAIN=.*/TOOLCHAIN=rust/' "$work/package.conf"
run_build "$IMAGE" "$work" "${shim_args[@]}" --env CURL_FAIL_TIMES=1

if grep -q 'simulated rustup fetch failure 1/1' "$BUILD_LOG" \
    && ! grep -q 'fetching the rustup installer failed after' "$BUILD_LOG"; then
    report pass "a transient rustup failure is retried rather than fatal"
else
    report fail "a transient rustup failure is retried rather than fatal" "log: $BUILD_LOG"
fi

rm -rf "$work"

summary
