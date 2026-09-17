#!/usr/bin/env bash
#
# Covers the YAML gate itself. Three things it has to do: accept the workflows,
# reject a duplicate mapping key (which GitHub rejects at parse time but
# yaml.safe_load accepts silently), and enforce the two estate conventions -
# every checkout sets persist-credentials: false, and every third-party action
# is pinned to a commit SHA.
#
# The convention cases include the two shapes a grep cannot get right: a with:
# block carrying other keys before the setting, and the second of two adjacent
# checkouts.
#
# Usage: tests/test-yamlcheck.sh

set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

repo="$(cd "$TESTS_DIR/.." && pwd)"

if python3 "$repo/tests/yamlcheck.py" "$repo"/.github/workflows/*.yml >/dev/null; then
    report pass "the workflows pass the strict loader"
else
    report fail "the workflows pass the strict loader"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

printf 'on:\n  push:\njobs:\n  a:\n    runs-on: x\n  a:\n    runs-on: y\n' > "$tmp/dup.yml"
if python3 "$repo/tests/yamlcheck.py" "$tmp/dup.yml" >/dev/null 2>&1; then
    report fail "a duplicate key is rejected" "the loader accepted it"
else
    report pass "a duplicate key is rejected"
fi

printf 'on:\n  push:\njobs:\n  a:\n    runs-on: x\n' > "$tmp/ok.yml"
if python3 "$repo/tests/yamlcheck.py" "$tmp/ok.yml" >/dev/null 2>&1; then
    report pass "a valid file is accepted"
else
    report fail "a valid file is accepted"
fi

# A glob matching no file must not report success having read nothing.
if python3 "$repo/tests/yamlcheck.py" >/dev/null 2>&1; then
    report fail "checking no files is not a pass" "it exited 0"
else
    report pass "checking no files is not a pass"
fi

# --- persist-credentials -----------------------------------------------------

yc() { python3 "$repo/tests/yamlcheck.py" "$@" >/dev/null 2>&1; }

printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@v7\n' > "$tmp/bare.yml"
if yc "$tmp/bare.yml"; then
    report fail "a checkout without persist-credentials is rejected" "it was accepted"
else
    report pass "a checkout without persist-credentials is rejected"
fi

printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@v7\n        with:\n          persist-credentials: true\n' > "$tmp/true.yml"
if yc "$tmp/true.yml"; then
    report fail "persist-credentials: true is rejected" "it was accepted"
else
    report pass "persist-credentials: true is rejected"
fi

# The setting four keys deep. A -A1 or -A2 window misses this and calls a
# correct workflow broken.
printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@v7\n        with:\n          repository: pkghaus/packages\n          path: packages\n          fetch-depth: 0\n          persist-credentials: false\n' > "$tmp/deep.yml"
if yc "$tmp/deep.yml"; then
    report pass "the setting is found however deep in its own with: block"
else
    report fail "the setting is found however deep in its own with: block" "it was rejected"
fi

# Two checkouts, only the first compliant. A wide window reads the first one's
# setting and calls the second one fine.
printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/checkout@v7\n        with:\n          persist-credentials: false\n      - uses: actions/checkout@v7\n        with:\n          repository: pkghaus/packages\n' > "$tmp/two.yml"
if yc "$tmp/two.yml"; then
    report fail "a second checkout cannot borrow the first one's setting" "it was accepted"
else
    report pass "a second checkout cannot borrow the first one's setting"
fi

# A composite action declares its steps under runs:, not jobs:.
printf 'runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@v7\n' > "$tmp/composite.yml"
if yc "$tmp/composite.yml"; then
    report fail "a composite action's steps are walked too" "it was accepted"
else
    report pass "a composite action's steps are walked too"
fi

# --- SHA pinning -------------------------------------------------------------

printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: dorny/paths-filter@v3\n' > "$tmp/tag.yml"
if yc "$tmp/tag.yml"; then
    report fail "a third-party action on a tag is rejected" "it was accepted"
else
    report pass "a third-party action on a tag is rejected"
fi

printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: dorny/paths-filter@ceb8a2b8f2d89434be7ff52d3de7ec3738c5cc9d\n' > "$tmp/sha.yml"
if yc "$tmp/sha.yml"; then
    report pass "the same action pinned to a SHA is accepted"
else
    report fail "the same action pinned to a SHA is accepted" "it was rejected"
fi

# actions/* and pkghaus/* stay on major tags deliberately, and ./ is local.
printf 'on: push\njobs:\n  a:\n    steps:\n      - uses: actions/setup-node@v7\n      - uses: pkghaus/signed-commit@v1\n      - uses: ./.github/actions/install-aptly\n' > "$tmp/first.yml"
if yc "$tmp/first.yml"; then
    report pass "first-party and local uses: stay exempt"
else
    report fail "first-party and local uses: stay exempt" "one was rejected"
fi

summary 12
