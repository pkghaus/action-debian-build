#!/usr/bin/env bash
#
# Covers the per-phase timing main() prints.
#
# It exists because 88% of this pipeline's runner time is inside entrypoint.sh
# and was, until now, a single number per build leg. The value is entirely in
# the output, so the output is what is asserted -- including the part that only
# matters on a bad day: a build that dies partway through still has to report
# the phases that finished, and must not claim a duration for the one that did
# not.
#
# Usage: tests/test-phase-timing.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

PHASES=(load_config dependencies get_sources build collect check)

# --- a successful build reports every phase and a total ----------------------
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -eq 0 ]; then
    report pass "the probe build succeeds"
else
    report fail "the probe build succeeds" "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

missing=""
for p in "${PHASES[@]}"; do
    grep -q "==> phase $p: [0-9]\+s" "$BUILD_LOG" || missing="$missing $p"
done
if [ -z "$missing" ]; then
    report pass "every phase reports a duration"
else
    report fail "every phase reports a duration" "missing:$missing; log: $BUILD_LOG"
fi

# The order is the pipeline. A reader scanning the log for where the time went
# should not have to reconstruct it.
order="$(grep -o '==> phase [a-z_]*' "$BUILD_LOG" | sed 's/==> phase //' | awk '!seen[$0]++' | tr '\n' ' ')"
if [ "$order" = "${PHASES[*]} " ]; then
    report pass "phases are reported in pipeline order"
else
    report fail "phases are reported in pipeline order" "got: $order"
fi

if grep -q '==> build complete in [0-9]\+s' "$BUILD_LOG"; then
    report pass "a completed build reports a total"
else
    report fail "a completed build reports a total" "log: $BUILD_LOG"
fi

# The cumulative figure is what makes the lines readable without arithmetic, so
# the last phase's cumulative and the total have to agree.
last_cumulative="$(grep -o 'cumulative [0-9]\+s' "$BUILD_LOG" | tail -1 | tr -dc '0-9')"
total="$(grep -o 'build complete in [0-9]\+s' "$BUILD_LOG" | tail -1 | tr -dc '0-9')"
if [ -n "$total" ] && [ "$last_cumulative" = "$total" ]; then
    report pass "the total matches the last cumulative figure"
else
    report fail "the total matches the last cumulative figure" \
        "cumulative=$last_cumulative total=$total"
fi

rm -rf "$work"

# --- a build that dies mid-phase reports only what finished ------------------
# The clone is failed deterministically by the same git shim test-retry.sh uses,
# with the attempt budget at 1 so the failure is immediate.
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work" \
    --volume "$TESTS_DIR/fake-git:/usr/local/bin/git:ro" \
    --env GIT_FAIL_TIMES=99 --env CLONE_ATTEMPTS=1

if [ "$BUILD_STATUS" -ne 0 ]; then
    report pass "the failing probe build fails"
else
    report fail "the failing probe build fails" "status=0; log: $BUILD_LOG"
fi

if grep -q '==> phase load_config' "$BUILD_LOG" \
    && grep -q '==> phase dependencies' "$BUILD_LOG"; then
    report pass "phases before the failure are still reported"
else
    report fail "phases before the failure are still reported" "log: $BUILD_LOG"
fi

# The load-bearing one. Timing a phase that did not finish would report a
# duration for work that never happened, which is worse than reporting nothing.
if grep -q '==> phase get_sources' "$BUILD_LOG"; then
    report fail "the phase that failed reports no duration" "log: $BUILD_LOG"
else
    report pass "the phase that failed reports no duration"
fi

if grep -q '==> build complete' "$BUILD_LOG"; then
    report fail "a failed build claims no total" "log: $BUILD_LOG"
else
    report pass "a failed build claims no total"
fi

rm -rf "$work"

summary
