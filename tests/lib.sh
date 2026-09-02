# Shared helpers for the test scripts. Sourced, not executed.
#
# Every test builds in a throwaway directory whose "upstream" is a git
# repository created inside the builder image, so the suite never touches the
# network and never depends on a third-party host staying up.

# shellcheck shell=bash

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass_count=0
fail_count=0

report() {
    local status="$1" name="$2" detail="${3:-}"

    if [ "$status" = pass ]; then
        pass_count=$((pass_count + 1))
        printf 'PASS  %s\n' "$name"
    else
        fail_count=$((fail_count + 1))
        printf 'FAIL  %s%s\n' "$name" "${detail:+ -- $detail}" >&2
    fi
}

summary() {
    printf '\n%s passed, %s failed\n' "$pass_count" "$fail_count"
    [ "$fail_count" -eq 0 ]
}

# Creates a packaging repo in a fresh directory and echoes its path. The caller
# owns the directory and is responsible for removing it.
make_workdir() {
    local image="$1" work
    work="$(mktemp -d)"

    cp -a "$TESTS_DIR/fixture/." "$work/"

    # Modes as git records them. A checkout with the executable bit set makes
    # debhelper treat a config file such as debian/docs as an executable config
    # and try to run it.
    find "$work/debian" -type f ! -name rules -exec chmod 0644 {} +
    chmod 0755 "$work/debian/rules"

    # Runs as container root against a directory owned by the invoking user.
    # Locally both are root; on a CI runner they differ, so git needs the path
    # marked safe, and the root-created .git tree needs opening up or the
    # runner user cannot delete the workdir afterwards.
    docker run --rm \
        --volume "$work:/target" \
        --workdir /target/upstream \
        --entrypoint sh \
        "$image" -c '
            set -eu
            git config --global --add safe.directory /target/upstream
            git init -q -b main .
            git add -A
            git -c user.name=fixture -c user.email=fixture@example.net \
                commit -qm "fixture upstream"
            git tag v0.0.1
            chmod -R a+rwX /target
        ' >/dev/null

    printf '%s\n' "$work"
}

# Like make_workdir, but the fixture's upstream/ contents are hoisted to the top
# level (a native package's source root is the packaging directory itself) and
# no git repository is created, because nothing is cloned.
make_native_workdir() {
    local work
    work="$(mktemp -d)"
    cp -a "$TESTS_DIR/fixture/." "$work/"

    mv "$work/upstream"/* "$work/"
    rmdir "$work/upstream"

    printf '3.0 (native)\n' > "$work/debian/source/format"
    # Native versions carry no Debian revision.
    sed -i '1s/(0\.0\.1-1)/(0.0.1)/' "$work/debian/changelog"
    printf '# A native package: no UPSTREAM, no VERSION.\nTOOLCHAIN=none\nDBGSYM=0\n' \
        > "$work/package.conf"

    find "$work/debian" -type f ! -name rules -exec chmod 0644 {} +
    chmod 0755 "$work/debian/rules"
    chmod -R a+rwX "$work"
    printf '%s\n' "$work"
}

# run_build <image> <workdir> [docker args...] -- captures combined output in
# BUILD_LOG and the exit status in BUILD_STATUS rather than failing the script,
# so tests can assert on failures too.
run_build() {
    local image="$1" work="$2"
    shift 2

    BUILD_LOG="$(mktemp)"
    set +e
    # The safe.directory override exists for the file:// clone of the fixture
    # upstream: on a runner its top directory belongs to the runner user while
    # the container clones as root. Production clones are remote transports,
    # where no ownership check applies.
    docker run --rm \
        --volume "$work:/target" \
        --workdir /target \
        --env GIT_CONFIG_COUNT=1 \
        --env GIT_CONFIG_KEY_0=safe.directory \
        --env "GIT_CONFIG_VALUE_0=*" \
        "$@" \
        "$image" > "$BUILD_LOG" 2>&1
    # Consumed by the sourcing test scripts, which shellcheck cannot see.
    # shellcheck disable=SC2034
    BUILD_STATUS=$?
    set -e
}

debs_in() {
    find "$1/debs" -name '*.deb' 2>/dev/null | sort
}

count_debs() {
    debs_in "$1" | wc -l | tr -d ' '
}
