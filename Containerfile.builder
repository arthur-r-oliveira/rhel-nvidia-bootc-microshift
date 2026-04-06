# Toolchain + kernel-devel layered on the same bootc base as the final image so kmod NVR matches kernel-core.
# Build: podman build --build-arg-file argfile.conf -f Containerfile.builder -t "${BUILDER_IMAGE}" …
# See https://github.com/coreos/fedora-bootc-nvidia (Containerfile.builder + BUILDER_IMAGE).
ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG EUS_RELEASE
ENV EUS_RELEASE=${EUS_RELEASE}

USER root
WORKDIR /root

COPY scripts/image/rhsm-enable-eus-in-container.sh /usr/bin/rhsm-enable-eus-in-container.sh
COPY scripts/image/dnf-refresh-all.sh /usr/bin/dnf-refresh-all.sh
COPY scripts/image/dnf-bootstrap-builder.sh /usr/bin/dnf-bootstrap-builder.sh
RUN chmod 755 /usr/bin/rhsm-enable-eus-in-container.sh /usr/bin/dnf-refresh-all.sh /usr/bin/dnf-bootstrap-builder.sh \
    && /usr/bin/dnf-refresh-all.sh \
    && /usr/bin/dnf-bootstrap-builder.sh
