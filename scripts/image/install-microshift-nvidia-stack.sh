#!/usr/bin/bash
# RHEL 9 bootc final image: public NVIDIA repos (Device Edge), MicroShift, driver stack, CRI-O GPU config.
set -euo pipefail

: "${DRIVER_VERSION:?}"
: "${CUDA_VERSION:?}"
: "${USHIFT_VER:?}"
: "${USER_PASSWD:?}"
: "${DRIVER_TYPE:?}"
: "${NVDP_IMAGE:?}"
USE_64K_PAGESIZE="${USE_64K_PAGESIZE:-0}"

# Second stage: full distro refresh again before enabling CUDA / MicroShift repos (matches builder kernel if metadata aligns).
/usr/bin/dnf-refresh-all.sh

nvidia_cuda_repo_url() {
    case "$(arch)" in
        x86_64) echo "https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo" ;;
        aarch64) echo "https://developer.download.nvidia.com/compute/cuda/repos/rhel9/sbsa/cuda-rhel9.repo" ;;
        *) echo "Unsupported arch $(arch) for NVIDIA CUDA repo" >&2; exit 1 ;;
    esac
}

yum_repos_d_writable() {
    touch /etc/yum.repos.d/.nvidia_bootc_write_test 2>/dev/null && rm -f /etc/yum.repos.d/.nvidia_bootc_write_test
}

# Step 1 (Device Edge): CUDA repo — use host-mounted .repo when /etc/yum.repos.d is read-only (EUS + podman --volume).
if [[ -f /etc/yum.repos.d/cuda-rhel9.repo ]] || dnf repolist --enabled 2>/dev/null | grep -qi cuda; then
    echo "Using existing CUDA repo (e.g. host /etc/yum.repos.d/cuda-rhel9.repo)."
elif yum_repos_d_writable; then
    curl -fsSL "$(nvidia_cuda_repo_url)" -o /etc/yum.repos.d/cuda-rhel9.repo
else
    echo "ERROR: CUDA repo missing and /etc/yum.repos.d is not writable (read-only mount?)." >&2
    echo "On the build host run: sudo ./scripts/host/configure-host-nvidia-build-repos.sh (repo root)." >&2
    exit 1
fi

if [ "$(arch)" = "aarch64" ]; then
    echo "sbsa" > /etc/dnf/vars/cudaarch
else
    echo "$(arch)" > /etc/dnf/vars/cudaarch
fi

if [ "$(arch)" = "aarch64" ] && [ "${USE_64K_PAGESIZE}" = "1" ]; then
    cd /tmp
    KERNEL_VERSION="$(rpm -q --qf "%{VERSION}-%{RELEASE}" kernel-core).$(arch)"
    dnf download -y kernel-64k{,-core,-modules{,-core}}-${KERNEL_VERSION}
    rpm-ostree override replace kernel-64k-*.rpm
    rpm-ostree override remove kernel{,-core,-modules{,-core}}
    rm -rf "/lib/modules/${KERNEL_VERSION}"
fi

export DRIVER_STREAM="$(echo "${DRIVER_VERSION}" | cut -d '.' -f 1)"
CUDA_VERSION_ARRAY=(${CUDA_VERSION//./ })
CUDA_DASHED_VERSION=${CUDA_VERSION_ARRAY[0]}-${CUDA_VERSION_ARRAY[1]}

cp -a /etc/dnf/dnf.conf{,.tmp} && mv /etc/dnf/dnf.conf{.tmp,}
# bootc workaround (see bootc#637). Avoid dnf config-manager --save: same flags per transaction.
RHOCP_REPO="rhocp-${USHIFT_VER}-for-rhel-9-$(uname -m)-rpms"
FAST_REPO="fast-datapath-for-rhel-9-$(uname -m)-rpms"
DNF_OPTS=(
    --best
    --setopt=install_weak_deps=False
    --setopt=tsflags=nodocs
)
# Host can enable these in redhat.repo before podman build (configure-host-microshift-build-repos.sh);
# with a ro yum.repos.d mount, the container cannot flip enabled=1 without --enablerepo.
_repolist_q=$(dnf repolist --enabled -q 2>/dev/null || true)
if [[ "${_repolist_q}" == *"${RHOCP_REPO}"* ]] && [[ "${_repolist_q}" == *"${FAST_REPO}"* ]]; then
    echo "MicroShift repos already enabled (e.g. host RHSM + mounted yum.repos.d): ${RHOCP_REPO}, ${FAST_REPO}"
else
    DNF_OPTS+=(--enablerepo="${RHOCP_REPO}" --enablerepo="${FAST_REPO}")
fi

dnf "${DNF_OPTS[@]}" -y module enable "nvidia-driver:${DRIVER_STREAM}-open/default"

dnf "${DNF_OPTS[@]}" install -y python3-dnf-plugin-versionlock

LOCKLIST=""
for _p in kernel-core kernel-modules kernel-modules-core kernel; do
    if _q=$(rpm -q "${_p}" 2>/dev/null); then
        [ -n "${LOCKLIST}" ] && LOCKLIST="${LOCKLIST} "
        LOCKLIST="${LOCKLIST}${_q}"
    fi
done
if [ -n "${LOCKLIST}" ]; then
    dnf "${DNF_OPTS[@]}" versionlock add ${LOCKLIST}
else
    echo "WARN: no kernel packages to versionlock"
fi

KMOD_RPM=$(ls /rpms/kmod-nvidia-*.rpm | head -1)
K_BASE_FULL=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n')
K_BASE_VERREL=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}\n')
KMOD_REQ=$(rpm -qp --requires "${KMOD_RPM}")
KMOD_BASE=$(basename "${KMOD_RPM}")
if ! echo "${KMOD_REQ}" | grep -qF "${K_BASE_FULL}" \
    && ! echo "${KMOD_REQ}" | grep -qF "${K_BASE_VERREL}" \
    && ! echo "${KMOD_BASE}" | grep -qF "${K_BASE_VERREL}"; then
    echo "ERROR: Built kmod-nvidia does not match BASE_IMAGE kernel-core."
    echo "  kernel-core: ${K_BASE_FULL}"
    echo "  kmod RPM: ${KMOD_RPM}"
    echo "  Requires (kernel-related):"; echo "${KMOD_REQ}" | grep -E 'kernel|uname|depmod' || echo "${KMOD_REQ}"
    exit 1
fi

# Step 2 (Device Edge): NVIDIA Container Toolkit stable repo
if [[ -f /etc/yum.repos.d/nvidia-container-toolkit.repo ]]; then
    echo "Using existing nvidia-container-toolkit.repo (host-mounted)."
elif yum_repos_d_writable; then
    curl -sL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        -o /etc/yum.repos.d/nvidia-container-toolkit.repo
else
    echo "ERROR: nvidia-container-toolkit.repo missing and /etc/yum.repos.d is read-only." >&2
    echo "On the build host run: sudo scripts/host/configure-host-nvidia-build-repos.sh" >&2
    exit 1
fi

dnf "${DNF_OPTS[@]}" install -y \
    /rpms/kmod-nvidia-*.rpm \
    cloud-init \
    firewalld \
    jq \
    microshift \
    microshift-release-info \
    pciutils \
    skopeo \
    "nvidia-driver-${DRIVER_VERSION}" \
    "nvidia-driver-cuda-${DRIVER_VERSION}" \
    "nvidia-driver-libs-${DRIVER_VERSION}" \
    "cuda-compat-${CUDA_DASHED_VERSION}" \
    "cuda-cudart-${CUDA_DASHED_VERSION}" \
    "nvidia-persistenced-${DRIVER_VERSION}" \
    nvidia-container-toolkit

if [ "${DRIVER_TYPE}" != "vgpu" ]; then
    dnf "${DNF_OPTS[@]}" install -y nvidia-fabric-manager libnvidia-nscq || true
fi

KD=$(rpm -qa 'kernel-debug*')
if [ -n "${KD}" ]; then
    dnf "${DNF_OPTS[@]}" remove -y ${KD}
fi

dnf "${DNF_OPTS[@]}" clean all
rm -rf /rpms

if getent group hugetlbfs >/dev/null; then
    printf 'g hugetlbfs %s\n' "$(getent group hugetlbfs | cut -d: -f3)" \
        > /usr/lib/sysusers.d/05-hugetlbfs-bootc-lint.conf
fi

systemd-sysusers
echo "redhat:${USER_PASSWD}" | chpasswd

systemctl enable microshift
systemctl enable firewalld
firewall-offline-cmd --zone=public --add-port=22/tcp
firewall-offline-cmd --zone=trusted --add-source=10.42.0.0/16
firewall-offline-cmd --zone=trusted --add-source=169.254.169.1
systemctl enable microshift-make-rshared.service
rm -f /usr/lib/systemd/system/default.target.wants/bootc-fetch-apply-updates.timer
ln -s ../cloud-init.target /usr/lib/systemd/system/default.target.wants/cloud-init.target
systemctl enable nvidia-toolkit-firstboot.service

echo "blacklist nouveau" > /etc/modprobe.d/blacklist_nouveau.conf

if [ -f /usr/lib/systemd/system/nvidia-fabricmanager.service ]; then
    sed -i '/\[Unit\]/a ConditionDirectoryNotEmpty=/proc/driver/nvidia-nvswitch/devices' \
        /usr/lib/systemd/system/nvidia-fabricmanager.service
    ln -sf /usr/lib/systemd/system/nvidia-fabricmanager.service \
        /etc/systemd/system/multi-user.target.wants/nvidia-fabricmanager.service
fi

ln -sf /usr/lib/systemd/system/nvidia-persistenced.service \
    /etc/systemd/system/multi-user.target.wants/nvidia-persistenced.service

nvidia-ctk runtime configure --runtime=crio --set-as-default \
    --drop-in-config=/etc/crio/crio.conf.d/99-nvidia.conf

if [ -f /etc/crio/crio.conf.d/microshift.conf ]; then
    mv /etc/crio/crio.conf.d/microshift.conf /etc/crio/crio.conf.d/10-microshift.conf
fi
if [ -f /etc/crio/crio.conf.d/microshift-ovn.conf ]; then
    mv /etc/crio/crio.conf.d/microshift-ovn.conf /etc/crio/crio.conf.d/11-microshift-ovn.conf
fi

sed -i 's/^runtimes =.*$/runtimes = ["crun", "docker-runc", "runc"]/g' \
    /etc/nvidia-container-runtime/config.toml

setsebool -P container_use_devices on

sed -i "s|__NVDP_IMAGE__|${NVDP_IMAGE}|g" \
    /etc/microshift/manifests.d/nvidia-device-plugin/nvidia-device-plugin.yaml
