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
