#!/usr/bin/env bash
#
# Covers signing the .dsc. The key is optional: with none supplied the source
# package is unsigned, which is what every build did before the input existed,
# so the first assertion is a regression guard on the default.
#
# What makes this worth its own file is that two of the decisions are invisible
# when wrong. The clock is pinned because an OpenPGP signature carries its
# creation time and six legs build the same source package; unpinned, each leg
# signs a different .dsc and five of the six .buildinfo records end up naming a
# file nobody can fetch. And the pin is CLAMPED to the key's creation, because
# gpg refuses to sign with a key the clock says does not exist yet and the
# archive routinely rebuilds a tag weeks after it was cut. The fixture's
# changelog is dated well before any key this suite generates, so the clamp is
# on the normal path here rather than an edge case someone has to remember.
#
# Usage: tests/test-source-signing.sh <builder-image>

set -euo pipefail

IMAGE="${1:?usage: $0 <builder-image>}"
# shellcheck source=tests/lib.sh
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

suite="$(docker run --rm --entrypoint sh "$IMAGE" -c 'printf %s "$DEB_SUITE"')"
case "$suite" in
    unstable | sid) qualifier="" ;;
    testing)        qualifier="~testing1" ;;
    *)              qualifier="~haus$(docker run --rm --entrypoint sh "$IMAGE" \
                        -c '. /etc/os-release && printf %s "$VERSION_ID"')+1" ;;
esac
dsc="deb-build-fixture_0.0.1-1${qualifier}.dsc"
buildinfo_glob="deb-build-fixture_0.0.1-1${qualifier}_*.buildinfo"

# A throwaway key shaped like the archive's: a certify-only primary and an
# ed25519 signing subkey, exported the way the CI secret is (subkey only,
# passphrase-less).
keyhome="$(mktemp -d)"
chmod 700 "$keyhome"
export GNUPGHOME="$keyhome"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-generate-key 'test source signing <src@example.invalid>' ed25519 cert 2y >/dev/null 2>&1
primary="$(gpg --list-keys --with-colons | awk -F: '$1 == "fpr" {print $10; exit}')"
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
    --quick-add-key "$primary" ed25519 sign 2y >/dev/null 2>&1
subkey="$(gpg --list-keys --with-colons | awk -F: '$1 == "sub" {f=1} f && $1 == "fpr" {print $10; exit}')"
key_created="$(gpg --list-keys --with-colons | awk -F: '$1 == "sub" {print $6; exit}')"
gpg --batch --armor --export-secret-subkeys "${subkey}!" > "$keyhome/secret.asc"
gpg --batch --export "${subkey}!" > "$keyhome/public.gpg"

cleanup() { rm -rf "$keyhome"; }
trap cleanup EXIT

# --- the default: no key, no signature --------------------------------------
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work"
if [ -f "$work/debs/$dsc" ] && ! head -1 "$work/debs/$dsc" | grep -q 'BEGIN PGP'; then
    report pass "with no key supplied the .dsc is unsigned"
else
    report fail "with no key supplied the .dsc is unsigned" \
        "head: $(head -1 "$work/debs/$dsc" 2>/dev/null); log: $BUILD_LOG"
fi
rm -rf "$work"

# --- a key supplied ---------------------------------------------------------
SOURCE_SIGNING_KEY="$(cat "$keyhome/secret.asc")"
export SOURCE_SIGNING_KEY

work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work" --env SOURCE_SIGNING_KEY
signed="$work/debs/$dsc"

if [ -f "$signed" ] && head -1 "$signed" | grep -q 'BEGIN PGP SIGNED MESSAGE'; then
    report pass "a supplied key produces a clearsigned .dsc"
else
    report fail "a supplied key produces a clearsigned .dsc" \
        "status=$BUILD_STATUS; head: $(head -1 "$signed" 2>/dev/null); log: $BUILD_LOG"
fi

# Verified with the PUBLIC subkey alone, which is all a user downloading from
# buildinfos.pkg.haus will have.
if gpg --no-default-keyring --keyring "$keyhome/public.gpg" \
       --verify "$signed" >/dev/null 2>&1; then
    report pass "the signature verifies against the public subkey alone"
else
    report fail "the signature verifies against the public subkey alone" \
        "$(gpg --no-default-keyring --keyring "$keyhome/public.gpg" --verify "$signed" 2>&1 | tail -2)"
fi

# entrypoint.sh runs under `set -x`, which expands and prints its arguments. The
# emptiness test and the import both take the key as an argument, so without
# suppression the armored private half lands in the build log in full. CI would
# probably mask it, since GitHub masks registered secrets; a local `docker run`
# masks nothing, and a private key should not depend on either.
if grep -q 'BEGIN PGP PRIVATE KEY BLOCK' "$BUILD_LOG"; then
    report fail "the signing key never reaches the build log" \
        "armor header found at $(grep -n 'BEGIN PGP PRIVATE KEY BLOCK' "$BUILD_LOG" | head -1 | cut -d: -f1)"
elif grep -qFf <(awk 'length($0) > 40 && !/^-----/' "$keyhome/secret.asc") "$BUILD_LOG"; then
    report fail "the signing key never reaches the build log" "a key body line appears in it"
else
    report pass "the signing key never reaches the build log"
fi

# The reason signing happens inside dpkg-buildpackage rather than afterwards:
# the record names a checksum OF the .dsc, and dpkg recomputes it once the file
# is signed. Signing after the record was written would leave every published
# .buildinfo describing a .dsc that no longer exists.
# Both this assertion and the determinism one below check for the signature
# first. Without that they pass against a builder that signs nothing at all:
# an unsigned .dsc matches its own record, and two unsigned builds agree.
record="$(find "$work/debs" -name "$buildinfo_glob" -print -quit)"
recorded="$(awk '/^Checksums-Sha256:/ {f=1; next}
                 f && /^ / { if ($3 ~ /\.dsc$/) print $1 }
                 f && !/^ / { exit }' "$record" 2>/dev/null)"
actual="$(sha256sum "$signed" | cut -d' ' -f1)"
if head -1 "$signed" | grep -q 'BEGIN PGP SIGNED MESSAGE' \
    && [ -n "$recorded" ] && [ "$recorded" = "$actual" ]; then
    report pass "the .buildinfo records the signed .dsc, not the unsigned one"
else
    report fail "the .buildinfo records the signed .dsc, not the unsigned one" \
        "recorded=[$recorded] actual=[$actual] record=[$record]"
fi

# The fixture's changelog predates any key this suite generates, so a pin at
# SOURCE_DATE_EPOCH would have failed the build outright with "Time conflict".
# Asserting the value, not just that the build survived: a clamp that silently
# used the wall clock would also survive, and would not reproduce.
if grep -q "clock pinned to $key_created" "$BUILD_LOG"; then
    report pass "the signing clock is clamped up to the key's creation"
else
    report fail "the signing clock is clamped up to the key's creation" \
        "wanted 'clock pinned to $key_created'; got: $(grep -o 'clock pinned to [0-9]*' "$BUILD_LOG" || echo none)"
fi

first="$(mktemp)"
cp "$signed" "$first"
rm -rf "$work"

# --- determinism, which is what lets six legs agree -------------------------
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work" --env SOURCE_SIGNING_KEY
if head -1 "$first" | grep -q 'BEGIN PGP SIGNED MESSAGE' \
    && cmp -s "$first" "$work/debs/$dsc"; then
    report pass "two builds of the same source sign to identical bytes"
else
    report fail "two builds of the same source sign to identical bytes" \
        "$(sha256sum "$first" "$work/debs/$dsc" 2>/dev/null | tr '\n' ' ')"
fi
rm -f "$first"
rm -rf "$work"

# --- failing closed ---------------------------------------------------------
# A secret that has gone bad must stop the build. Falling back to unsigned would
# publish unsigned source packages for as long as nobody opened one.
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work" --env SOURCE_SIGNING_KEY="not an OpenPGP key at all"
if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'could not import it' "$BUILD_LOG"; then
    report pass "an unreadable signing key fails the build"
else
    report fail "an unreadable signing key fails the build" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi
rm -rf "$work"

# A certify-only key imports cleanly and can sign nothing. Distinct from the
# case above because the import succeeds, so only the capability check catches
# it.
gpg --batch --armor --export-secret-keys "${primary}!" > "$keyhome/certonly.asc" 2>/dev/null
work="$(make_workdir "$IMAGE")"
run_build "$IMAGE" "$work" --env "SOURCE_SIGNING_KEY=$(cat "$keyhome/certonly.asc")"
if [ "$BUILD_STATUS" -ne 0 ] && grep -q 'no signing subkey' "$BUILD_LOG"; then
    report pass "a key with no signing subkey fails the build"
else
    report fail "a key with no signing subkey fails the build" \
        "status=$BUILD_STATUS; log: $BUILD_LOG"
fi
rm -rf "$work"

summary 9
