#!/usr/bin/env bash
#
# Runs the whole suite against one builder image.
#
# Usage: tests/run.sh [builder-image]
#
# With no image, builds one for the current stable suite first.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
image="${1:-}"

if [ -z "$image" ]; then
    image=deb-builder:test
    echo "==> building $image"
    docker build --build-arg SUITE=trixie --tag "$image" "$repo"
fi

status=0

# The per-file guard in summary() catches a file whose assertions stop running.
# It cannot catch a file that stops being run at all, because a deleted or
# renamed test simply drops out of the glob below and the suite still passes.
EXPECTED_SUITES=11
found=$(printf '%s\n' "$here"/test-*.sh | wc -l)
if [ "$found" -ne "$EXPECTED_SUITES" ]; then
    echo "FAIL: $found test files, expected $EXPECTED_SUITES." >&2
    echo "      A suite was added or removed; update EXPECTED_SUITES." >&2
    exit 1
fi

for test in "$here"/test-*.sh; do
    echo
    echo "==> $(basename "$test")"

    case "$(basename "$test")" in
        test-yamlcheck.sh|test-dep8-extra.sh|test-image-ref.sh) "$test" || status=1 ;;
        *)                 "$test" "$image" || status=1 ;;
    esac
done

echo
if [ "$status" -eq 0 ]; then
    echo "all suites passed"
else
    echo "one or more suites failed" >&2
fi

exit "$status"
