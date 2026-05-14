# Single-stage bootc: RHEL 10.1+ Red Hat–signed OpenRM NVIDIA (Extensions/Supplementary + rhel-drivers)
# and Red Hat build of MicroShift 4.21 on RHEL 10 repos (see OCPBUGS-83693 / rhocp-4.21-for-rhel-10).
# Build: ./test-build.sh (argfile.conf must set SINGLE_STAGE_BOOTC=1 — no Containerfile.builder).
ARG BASE_IMAGE

FROM ${BASE_IMAGE}

ARG VENDOR
LABEL vendor=${VENDOR} \
      org.opencontainers.image.vendor=${VENDOR}

ARG DRIVER_TYPE
ENV DRIVER_TYPE=${DRIVER_TYPE}

ARG USHIFT_VER
ENV USHIFT_VER=${USHIFT_VER}

ARG RHEL_MAJOR=10
ENV RHEL_MAJOR=${RHEL_MAJOR}

ARG USER_PASSWD
ENV USER_PASSWD=${USER_PASSWD}

ARG NVDP_IMAGE
ENV NVDP_IMAGE=${NVDP_IMAGE}

ARG USE_64K_PAGESIZE
ENV USE_64K_PAGESIZE=${USE_64K_PAGESIZE}

USER root

COPY scripts/image/dnf-refresh-all.sh /usr/bin/dnf-refresh-all.sh
RUN chmod 755 /usr/bin/dnf-refresh-all.sh

COPY etc /etc
COPY scripts/image/microshift-copy-images /usr/bin/microshift-copy-images
COPY scripts/image/embed-microshift-images.sh /usr/bin/embed-microshift-images.sh
COPY scripts/image/bootc-finalize-for-lint.sh /usr/bin/bootc-finalize-for-lint.sh
COPY usr/lib/sysusers.d/10-microshift-nvidia-bootc.conf /usr/lib/sysusers.d/10-microshift-nvidia-bootc.conf

COPY scripts/image/enable-rhel10-nvidia-repos.sh /usr/bin/enable-rhel10-nvidia-repos.sh
COPY scripts/image/install-microshift-nvidia-oss-rhel10.sh /usr/bin/install-microshift-nvidia-oss-rhel10.sh

RUN chmod 755 /usr/bin/enable-rhel10-nvidia-repos.sh /usr/bin/install-microshift-nvidia-oss-rhel10.sh \
    && /usr/bin/install-microshift-nvidia-oss-rhel10.sh

ENV IMAGE_STORAGE_DIR=/usr/lib/containers/storage
ENV IMAGE_LIST_FILE=${IMAGE_STORAGE_DIR}/image-list.txt

COPY scripts/image/verify-nvidia-kmod.sh /usr/bin/verify-nvidia-kmod.sh
RUN chmod 755 /usr/bin/verify-nvidia-kmod.sh && /usr/bin/verify-nvidia-kmod.sh

RUN --mount=type=secret,id=pullsecret,dst=/run/secrets/pull-secret.json \
    mkdir -p /etc/crio \
    && install -m 0600 /run/secrets/pull-secret.json /etc/crio/openshift-pull-secret \
    && mkdir -p "${IMAGE_STORAGE_DIR}" \
    && chmod 755 /usr/bin/embed-microshift-images.sh \
    && NVDP_IMAGE="${NVDP_IMAGE}" /usr/bin/embed-microshift-images.sh

RUN chmod 755 /usr/bin/microshift-copy-images

ARG IMAGE_VERSION_ID
LABEL image_version_id="${IMAGE_VERSION_ID}"

RUN chmod 755 /usr/bin/bootc-finalize-for-lint.sh && /usr/bin/bootc-finalize-for-lint.sh
