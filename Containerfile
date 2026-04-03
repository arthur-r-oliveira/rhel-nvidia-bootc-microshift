# kmod builder image must be built first from the same BASE_IMAGE (Containerfile.builder). All build args: argfile.conf only.
ARG BUILDER_IMAGE
ARG BASE_IMAGE

FROM ${BUILDER_IMAGE} AS builder

ARG EUS_RELEASE
ENV EUS_RELEASE=${EUS_RELEASE}
ARG BASE_URL
ARG DRIVER_VERSION
ARG USE_64K_PAGESIZE
ARG VENDOR
ARG RPM_HOST

USER root
WORKDIR /root
COPY x509-configuration.ini x509-configuration.ini
COPY scripts/build-kmod-nvidia-precompiled.sh /root/build-kmod-nvidia-precompiled.sh

ENV BASE_URL=${BASE_URL} \
    DRIVER_VERSION=${DRIVER_VERSION} \
    USE_64K_PAGESIZE=${USE_64K_PAGESIZE} \
    VENDOR=${VENDOR} \
    RPM_HOST=${RPM_HOST}

RUN chmod 755 /root/build-kmod-nvidia-precompiled.sh \
    && /root/build-kmod-nvidia-precompiled.sh

FROM ${BASE_IMAGE}

ARG EUS_RELEASE
ENV EUS_RELEASE=${EUS_RELEASE}
ARG VENDOR
LABEL vendor=${VENDOR} \
      org.opencontainers.image.vendor=${VENDOR}

ARG DRIVER_TYPE
ENV NVIDIA_DRIVER_TYPE=${DRIVER_TYPE} \
    DRIVER_TYPE=${DRIVER_TYPE}

ARG DRIVER_VERSION
ENV NVIDIA_DRIVER_VERSION=${DRIVER_VERSION} \
    DRIVER_VERSION=${DRIVER_VERSION}

ARG CUDA_VERSION
ENV CUDA_VERSION=${CUDA_VERSION}

ARG DISABLE_VGPU_VERSION_CHECK
ENV DISABLE_VGPU_VERSION_CHECK=${DISABLE_VGPU_VERSION_CHECK}

ARG USHIFT_VER
ENV USHIFT_VER=${USHIFT_VER}
ARG USER_PASSWD
ENV USER_PASSWD=${USER_PASSWD}
ARG NVDP_IMAGE
ENV NVDP_IMAGE=${NVDP_IMAGE}

USER root

COPY scripts/rhsm-enable-eus-in-container.sh /usr/bin/rhsm-enable-eus-in-container.sh
COPY scripts/dnf-refresh-all.sh /usr/bin/dnf-refresh-all.sh
COPY scripts/dnf-bootstrap-final.sh /usr/bin/dnf-bootstrap-final.sh
RUN chmod 755 /usr/bin/rhsm-enable-eus-in-container.sh /usr/bin/dnf-refresh-all.sh /usr/bin/dnf-bootstrap-final.sh \
   && /usr/bin/dnf-refresh-all.sh

COPY nvidia-toolkit-firstboot.service /usr/lib/systemd/system/nvidia-toolkit-firstboot.service
COPY etc /etc
COPY etc/systemd/system/microshift-make-rshared.service /etc/systemd/system/microshift-make-rshared.service
COPY scripts/microshift-copy-images /usr/bin/microshift-copy-images
COPY scripts/embed-microshift-images.sh /usr/bin/embed-microshift-images.sh
COPY scripts/bootc-finalize-for-lint.sh /usr/bin/bootc-finalize-for-lint.sh
COPY usr/lib/sysusers.d/10-microshift-nvidia-bootc.conf /usr/lib/sysusers.d/10-microshift-nvidia-bootc.conf

ARG USE_64K_PAGESIZE
ENV USE_64K_PAGESIZE=${USE_64K_PAGESIZE}

COPY --from=builder /root/yum-packaging-precompiled-kmod/RPMS/*/*.rpm /rpms/

COPY scripts/install-microshift-nvidia-stack.sh /usr/bin/install-microshift-nvidia-stack.sh

RUN chmod 755 /usr/bin/install-microshift-nvidia-stack.sh \
    && /usr/bin/install-microshift-nvidia-stack.sh

ENV IMAGE_STORAGE_DIR=/usr/lib/containers/storage
ENV IMAGE_LIST_FILE=${IMAGE_STORAGE_DIR}/image-list.txt

COPY scripts/verify-nvidia-kmod.sh /usr/bin/verify-nvidia-kmod.sh
RUN chmod 755 /usr/bin/verify-nvidia-kmod.sh && /usr/bin/verify-nvidia-kmod.sh

RUN mkdir -p /etc/skel/.config/containers
COPY containers-storage.conf /etc/skel/.config/containers/storage.conf

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
