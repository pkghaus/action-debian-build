# SUITE names the Debian suite and is baked into the image so artifacts can
# identify themselves. BASE_IMAGE defaults to the matching Debian image but may
# point anywhere, so a fork can publish Ubuntu-based builders without editing
# this file.
ARG SUITE=trixie
ARG BASE_IMAGE=debian:${SUITE}-slim

FROM ${BASE_IMAGE}

# Re-declared: an ARG before FROM is not in scope in the build stage.
ARG SUITE

ENV DEB_SUITE=${SUITE} \
    DEBIAN_FRONTEND=noninteractive

# Only the fixed tooling the entrypoint itself needs:
#
#   dpkg-dev         dpkg-buildpackage, dpkg-source, dpkg-parsechangelog
#   fakeroot         dpkg-buildpackage's default root command
#   lintian          packaging checks, gated by the LINTIAN setting
#   git              cloning the upstream project
#   curl             fetching rustup when TOOLCHAIN=rust
#   ca-certificates  verifying both of the above over TLS
#
# Package build dependencies are resolved from debian/control at build time by
# apt-get build-dep, which is why the apt indexes are cleaned here rather than
# kept: the entrypoint refreshes them anyway. Installing devscripts and equivs
# to get mk-build-deps instead would drag in debhelper and a full C toolchain,
# tripling the image for output that is byte-identical.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        dpkg-dev \
        fakeroot \
        git \
        lintian \
    && rm -rf /var/lib/apt/lists/*

# Backports, for the one suite that has a POPULATED one. Enabled by content,
# not by existence: `testing-backports` is a real, signed, NotAutomatic archive
# that currently carries zero packages (Codename forky-backports, its
# main/binary-amd64/Packages declared as 0 bytes against trixie-backports'
# 2481633), so an existence check enables an apt source that indexes nothing.
# Reading the size out of Release is one small fetch, is architecture-neutral,
# and switches forky on by itself the day it fills - where a hardcoded codename
# would go stale at the next stable transition.
#
# Safe by construction, and measured rather than assumed: the suite carries
# NotAutomatic: yes, which apt reads as priority 100 against a default of 500.
# A package already satisfiable from the suite proper is never pulled from here
# -- checked on curl, present in both, whose Candidate stays the trixie version
# while the backports one sits at priority 100 and is not chosen. Backports is
# reachable only for a Build-Depends the suite cannot satisfy at all.
#
# Added for zig, which requires LLVM 21.x exactly (its cmake/Findllvm.cmake
# rejects both 20 and 22) while trixie carries 19 and testing and unstable have
# moved to 22 and 23. Without this, a from-source zig cannot be built on stable.
RUN set -eu; \
    sz="$(curl -fsSL "http://deb.debian.org/debian/dists/${SUITE}-backports/Release" 2>/dev/null \
        | awk '/^SHA256:/{f=1;next} f && $3 ~ /^main\/binary-[^/]+\/Packages$/ && $2+0 > 0 {print $2; exit}')"; \
    if [ -n "${sz:-}" ]; then \
        printf 'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: %s-backports\nComponents: main\nSigned-By: /usr/share/keyrings/debian-archive-keyring.pgp\n' \
            "${SUITE}" > /etc/apt/sources.list.d/backports.sources; \
        echo "enabled ${SUITE}-backports (index ${sz} bytes)"; \
    else \
        echo "no populated ${SUITE}-backports archive; skipping"; \
    fi

LABEL org.opencontainers.image.title="deb-builder" \
      org.opencontainers.image.description="Debian package build environment for action-debian-build" \
      org.opencontainers.image.licenses="Apache-2.0"

# /usr/bin rather than /usr/local/bin, and the distinction is not cosmetic.
# dpkg records Build-Tainted-By: usr-local-has-programs in every .buildinfo it
# writes when /usr/local holds an executable, and this entrypoint was the only
# one in the image -- so every package this builder has ever produced carries
# that taint, caused by the builder itself rather than by anything about the
# package. Measured before and after: the field is present with the entrypoint
# in /usr/local and absent with it here.
COPY entrypoint.sh /usr/bin/deb-build
RUN chmod 0755 /usr/bin/deb-build

WORKDIR /target
ENTRYPOINT ["/usr/bin/deb-build"]
