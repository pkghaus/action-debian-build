#!/usr/bin/env bash
#
# Covers how the composite action resolves the builder image before running it.
#
# The step pulls the tag and inspects it for a digest, so the run is pinned to an
# immutable reference rather than to a tag that moves. Both of those steps fail
# for an image that was built on the runner and never pushed, which is exactly
# what this repository's own `action /` jobs use and what a fork building its own
# builder does. Neither is an error, and treating them as one broke all three
# `action /` jobs once already.
#
# The step is extracted from action.yml rather than copied, so this tests the
# shipped code. Only the resolution is exercised; the docker run itself belongs
# to a real build.
#
# This suite needs no builder image.
#
# The fake `docker` bodies below are single-quoted on purpose: their $1 and $*
# belong to the stub, and expanding them in this shell would substitute this
# script's own arguments. shellcheck reads that as a mistake.
# shellcheck disable=SC2016

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
    if st.get("name", "").startswith("Build Debian package"):
        open(sys.argv[2], "w").write(st["run"])
        break
else:
    raise SystemExit("no build step found in action.yml")
PY

# Runs the step with docker stubbed, so the resolution logic is what is tested
# and no image or daemon is needed. Output lands in STEP_OUTPUT, status in
# STEP_STATUS.
run_step() { # $1 = fake `docker` body
    local bin
    bin="$(mktemp -d)"
    printf '#!/bin/bash\n%s\n' "$1" > "$bin/docker"
    chmod +x "$bin/docker"
    set +e
    STEP_OUTPUT="$(
        PATH="$bin:$PATH" \
        GITHUB_WORKSPACE=/tmp WORKING_DIRECTORY=. \
        IMAGE="local/deb-builder" SUITE="trixie" \
        bash "$step" 2>&1
    )"
    STEP_STATUS=$?
    set -e
    rm -rf "$bin"
}

# --- a local image: pull denied, no RepoDigests -------------------------------
run_step '
case "$1" in
  pull) echo "Error response from daemon: pull access denied for local/deb-builder" >&2; exit 1 ;;
  image) exit 1 ;;
  run) echo "RAN: ${*: -1}" ;;
esac'
if [ "$STEP_STATUS" -eq 0 ]; then
    report pass "a local image that cannot be pulled is not an error"
else
    report fail "a local image that cannot be pulled is not an error" \
        "status=$STEP_STATUS output=[$STEP_OUTPUT]"
fi
case "$STEP_OUTPUT" in
    *"RAN: local/deb-builder:trixie"*) report pass "falls back to the tag when there is no digest" ;;
    *) report fail "falls back to the tag when there is no digest" "output=[$STEP_OUTPUT]" ;;
esac

# --- a registry image: pull works and a digest is reported --------------------
run_step '
case "$1" in
  pull) exit 0 ;;
  image) echo "ghcr.io/pkghaus/deb-builder@sha256:abc123" ;;
  run) echo "RAN: ${*: -1}" ;;
esac'
case "$STEP_OUTPUT" in
    *"RAN: ghcr.io/pkghaus/deb-builder@sha256:abc123"*)
        report pass "runs the resolved digest, not the tag" ;;
    *) report fail "runs the resolved digest, not the tag" "output=[$STEP_OUTPUT]" ;;
esac
case "$STEP_OUTPUT" in
    *"builder image: ghcr.io/pkghaus/deb-builder@sha256:abc123"*)
        report pass "logs the digest it resolved, so a build is auditable later" ;;
    *) report fail "logs the digest it resolved" "output=[$STEP_OUTPUT]" ;;
esac

summary
