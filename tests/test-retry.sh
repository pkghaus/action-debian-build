#!/usr/bin/env bash
#
# Covers the clone retry, which exists because GitHub cancels HTTP/2 streams
# when several builds clone the same repository at once.
#
# The failures are driven by a git shim rather than by timing, so the test is
# deterministic: no sleeping until a real upstream happens to recover.
#
# Usage: tests/test-retry.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

shim_args=(
    --volume "$TESTS_DIR/fake-git:/usr/local/bin/git:ro"
)

# --- a transient failure is retried and the build still succeeds -------------
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work" "${shim_args[@]}" --env GIT_FAIL_TIMES=2

if [ "$BUILD_STATUS" -eq 0 ] && [ "$(count_debs "$work")" -eq 1 ]; then
    report pass "transient clone failures are retried"
else
    report fail "transient clone failures are retried" \
        "status=$BUILD_STATUS debs=$(count_debs "$work"); log: $BUILD_LOG"
fi

# The label is the retried operation, so the line names what could not be
# fetched rather than only that a clone failed. Both attempts have to appear:
# a retry that reported only its last failure would hide how many there were.
if grep -q 'cloning .* attempt 1/5 failed' "$BUILD_LOG" \
    && grep -q 'cloning .* attempt 2/5 failed' "$BUILD_LOG"; then
    report pass "each failed attempt is reported"
else
    report fail "each failed attempt is reported" "log: $BUILD_LOG"
fi

# The shim leaves a partial checkout behind on failure. Reaching a successful
# build proves the retry clears it -- git would otherwise refuse to clone into
# a non-empty directory.
if grep -q 'simulated clone failure 2/2' "$BUILD_LOG" && [ "$BUILD_STATUS" -eq 0 ]; then
    report pass "a partial checkout does not block the retry"
else
    report fail "a partial checkout does not block the retry" "log: $BUILD_LOG"
fi

rm -rf "$work"

# --- exhausting the attempts fails loudly, and only after all of them --------
# The budget is lowered rather than left at its default: the backoff doubles, so
# a full run of five would spend 30s sleeping in every CI leg. The transient case
# above already proves the default is 5 by way of its "1/5" message.
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work" "${shim_args[@]}" \
    --env GIT_FAIL_TIMES=99 --env CLONE_ATTEMPTS=3

if [ "$BUILD_STATUS" -ne 0 ]; then
    report pass "exhausted retries fail the build"
else
    report fail "exhausted retries fail the build" "status=0; log: $BUILD_LOG"
fi

if grep -q 'failed after 3 attempts' "$BUILD_LOG"; then
    report pass "the failure names the attempt budget"
else
    report fail "the failure names the attempt budget" "log: $BUILD_LOG"
fi

attempts="$(grep -c 'simulated clone failure' "$BUILD_LOG" || true)"
if [ "$attempts" -eq 3 ]; then
    report pass "CLONE_ATTEMPTS bounds the number of attempts"
else
    report fail "CLONE_ATTEMPTS bounds the number of attempts" \
        "counted $attempts; log: $BUILD_LOG"
fi

rm -rf "$work"

summary
