#!/usr/bin/env bash
#
# A native package has no upstream. There is no release feed to track and no tag
# to clone: everything the package is made of already sits in the packaging
# directory, so UPSTREAM and VERSION describe nothing and must not be set.
#
# This exists because the archive keyring was built from a separate repository
# that was archived when the fleet became one repo. Builds kept working, because
# a read-only tag clone is permitted on an archived repository, so nothing went
# red -- but the key material could no longer be changed, and the first person
# to find out would have been whoever was rotating a signing key.
#
# Usage: tests/test-native.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

# --- a native package builds with no UPSTREAM -------------------------------
work="$(make_native_workdir)"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -eq 0 ] && [ "$(count_debs "$work")" -eq 1 ]; then
    report pass "a native package builds without UPSTREAM"
else
    report fail "a native package builds without UPSTREAM" \
        "status=$BUILD_STATUS debs=$(count_debs "$work"); log: $BUILD_LOG"
fi

# The source package is the whole point: without it the record is unusable.
if [ -n "$(find "$work/debs" -name '*.dsc' -print -quit)" ] \
   && [ -n "$(find "$work/debs" -name '*.tar.*' -print -quit)" ]; then
    report pass "a native package emits its .dsc and source tarball"
else
    report fail "a native package emits its .dsc and source tarball" \
        "debs: $(find "$work/debs" -type f -printf '%f ' 2>/dev/null)"
fi

# Build-Path, and the tarball's root, come from the changelog's source name
# rather than a repository basename that no longer exists.
if grep -q '^Build-Path: /build/deb-build-fixture$' "$work"/debs/*.buildinfo; then
    report pass "the source tree is named after the package, not a repository"
else
    report fail "the source tree is named after the package, not a repository" \
        "$(grep '^Build-Path:' "$work"/debs/*.buildinfo || echo 'no Build-Path')"
fi

# package.conf is build configuration, not source. No other package ships one
# inside its source package and this one must not either.
tar_contents="$(tar tf "$(find "$work/debs" -name '*.tar.*' -print -quit)")"
if printf '%s\n' "$tar_contents" | grep -q 'debian/rules$' \
   && printf '%s\n' "$tar_contents" | grep -q 'Makefile$' \
   && ! printf '%s\n' "$tar_contents" | grep -q 'package.conf$'; then
    report pass "the source package carries debian/ and the source, not package.conf"
else
    report fail "the source package carries debian/ and the source, not package.conf" \
        "$(printf '%s\n' "$tar_contents" | tr '\n' ' ')"
fi

# There is no upstream revision to record, so the file the builder writes for
# every other package must not appear with an empty or invented value.
if ! tar tf "$(find "$work/debs" -name '*.tar.*' -print -quit)" | grep -q 'debian/upstream-commit$'; then
    report pass "a native package's source carries no upstream-commit file"
else
    report fail "a native package's source carries no upstream-commit file"
fi

# An empty Repository field would read as a lookup that failed rather than a
# question that does not apply.
if grep -q '^Repository: none (native' "$work"/debs/*.source; then
    report pass "the .source says there is no upstream rather than leaving it blank"
else
    report fail "the .source says there is no upstream rather than leaving it blank" \
        "$(cat "$work"/debs/*.source 2>/dev/null | tr '\n' ' ')"
fi

rm -rf "$work"

# --- a native package that sets UPSTREAM is refused -------------------------
# Ignoring it would build something other than what package.conf appears to ask
# for, and a leftover value is likelier to be a stale file than an intention.
work="$(make_native_workdir)"
printf 'UPSTREAM=file:///target/nowhere\n' >> "$work/package.conf"
run_build "$IMAGE" "$work"

if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'native package and must not set UPSTREAM' "$BUILD_LOG"; then
    report pass "a native package setting UPSTREAM is refused"
else
    report fail "a native package setting UPSTREAM is refused" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi

rm -rf "$work"

summary
