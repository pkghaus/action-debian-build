#!/usr/bin/env bash
#
# Covers DEP8_EXTRA_DEBS parsing and validation in the composite action's DEP-8
# step. The value is interpolated into a shell command that runs apt-get inside
# a container, so what it is allowed to contain is a correctness question and
# not a style one.
#
# The values below are quoted, which is what makes this a test of the
# validation. package.conf is SOURCED, by this step and by the builder, so an
# unquoted `foo;id` runs `id` at source time and leaves the variable as plain
# `foo` -- there is nothing left for validation to reject, and nothing it could
# have prevented. Arbitrary shell in package.conf is that file's existing trust
# model. What validation covers is the value that survives sourcing and reaches
# the interpolation.
#
# The step is extracted from action.yml rather than copied here, so this tests
# the shipped code. Only the validation is exercised: everything after it
# installs packages and builds a testbed, which belongs to a real run.
#
# Enforced, not assumed -- see run_step. Nothing in the step itself stops after
# validation, so unguarded it runs on and fetches a real package from the real
# archive.
#
# This suite needs no builder image.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib.sh
. "$here/lib.sh"

repo="$(cd "$here/.." && pwd)"
step="$(mktemp)"
trap 'rm -f "$step"' EXIT

python3 - "$repo/action.yml" "$step" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for st in doc["runs"]["steps"]:
    if st.get("name", "").startswith("Run DEP-8"):
        open(sys.argv[2], "w").write(st["run"])
        break
else:
    raise SystemExit("no DEP-8 step found in action.yml")
PY

# Runs the step against a throwaway workspace holding one package.conf.
# Returns the step's output; status lands in STEP_STATUS.
#
# OFFLINE, and that is load-bearing rather than tidiness. Past validation the
# step installs autopkgtest, builds a testbed and fetches DEP8_EXTRA_DEBS from
# the LIVE archive -- and a valid value here is `i3lock-color`, a package
# apt.pkg.haus actually serves. Unguarded, eight CI runs fetching it six times
# each put 48 downloads into the archive's published statistics and carried
# i3lock-color to the top of them: a unit test for a `case` pattern outweighing
# every real user that day.
#
# `sudo` is the first command after validation and the step runs under `set -e`,
# so a failing stub stops it exactly at the edge of the branch this suite owns.
# `docker` is stubbed too, and its invocation recorded, so that a later
# reordering cannot quietly restore the fetch without failing a test.
run_step() {
    local conf_line="$1"
    local ws bin
    ws="$(mktemp -d)"
    bin="$(mktemp -d)"
    STEP_DOCKER_LOG="$bin/docker-calls"
    : > "$STEP_DOCKER_LOG"
    printf '#!/bin/sh\necho "tests: sudo is blocked" >&2\nexit 1\n' > "$bin/sudo"
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "$STEP_DOCKER_LOG" \
        > "$bin/docker"
    chmod 0755 "$bin/sudo" "$bin/docker"

    mkdir -p "$ws/debian/tests"
    : > "$ws/debian/tests/control"
    printf 'UPSTREAM=https://example.invalid/x.git\nVERSION=v1\n%s\n' "$conf_line" \
        > "$ws/package.conf"
    set +e
    STEP_OUTPUT="$(PATH="$bin:$PATH" GITHUB_WORKSPACE="$ws" WORKING_DIRECTORY=. \
        SUITE=trixie DEP8=on timeout 60 bash "$step" 2>&1)"
    STEP_STATUS=$?
    set -e
    STEP_DOCKER_CALLS="$(wc -l < "$STEP_DOCKER_LOG" | tr -d ' ')"
    rm -rf "$ws" "$bin"
}

# --- values that must be rejected --------------------------------------------
for bad in "DEP8_EXTRA_DEBS='foo; id'" "DEP8_EXTRA_DEBS='foo\$(id)'" \
           "DEP8_EXTRA_DEBS='foo\`id\`'" "DEP8_EXTRA_DEBS=FooBar" \
           "DEP8_EXTRA_DEBS=foo/bar" "DEP8_EXTRA_DEBS='foo && rm -rf /'"; do
    run_step "$bad"
    if [ "$STEP_STATUS" -ne 0 ] && \
       printf '%s' "$STEP_OUTPUT" | grep -q 'not a list of Debian package names'; then
        report pass "rejected: $bad"
    else
        report fail "rejected: $bad" \
            "status=$STEP_STATUS output=$(printf '%s' "$STEP_OUTPUT" | head -3)"
    fi
done

# --- values that must get past validation ------------------------------------
# A valid value cannot be run to completion here: the step goes on to install
# autopkgtest and build a testbed. What is asserted is that it was not rejected,
# which is the branch this suite owns.
for good in 'DEP8_EXTRA_DEBS=i3lock-color' 'DEP8_EXTRA_DEBS=libfoo1 bar-baz+x.y' \
            '# no extra debs declared'; do
    run_step "$good"
    if printf '%s' "$STEP_OUTPUT" | grep -q 'not a list of Debian package names'; then
        report fail "accepted: $good" "wrongly rejected"
    else
        report pass "accepted: $good"
    fi
    # The regression assertion. Reaching docker means reaching the fetch, and
    # the fetch means the live archive.
    if [ "${STEP_DOCKER_CALLS:-0}" -eq 0 ]; then
        report pass "  and stopped before touching the network"
    else
        report fail "  and stopped before touching the network" \
            "docker invoked ${STEP_DOCKER_CALLS}x: $(head -1 "$STEP_DOCKER_LOG" 2>/dev/null)"
    fi
done

summary 12
