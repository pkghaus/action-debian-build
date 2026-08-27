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

for test in "$here"/test-*.sh; do
    echo
    echo "==> $(basename "$test")"

    case "$(basename "$test")" in
        test-yamlcheck.sh|test-dep8-extra.sh) "$test" || status=1 ;;
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
