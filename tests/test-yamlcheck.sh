#!/usr/bin/env bash
#
# Covers the YAML gate itself: it has to accept the workflows and reject a
# duplicate mapping key, which is what GitHub rejects at parse time but
# yaml.safe_load accepts silently.
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

summary
