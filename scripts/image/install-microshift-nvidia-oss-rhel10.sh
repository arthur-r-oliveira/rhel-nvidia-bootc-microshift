#!/usr/bin/bash
# RHEL 10 bootc: Red Hat–signed OpenRM NVIDIA stack (Extensions/Supplementary) + MicroShift 4.2x + CRI-O GPU.
# Mirrors validated shell flow in rhel10-nvidia-gpu-ushift.txt: dnf install rhel-drivers → enable repos → rhel-drivers install nvidia.
set -euo pipefail

: "${USER_PASSWD:?}"
: "${USHIFT_VER:?}"
: "${NVDP_IMAGE:?}"
: "${DRIVER_TYPE:?}"

USE_64K_PAGESIZE="${USE_64K_PAGESIZE:-0}"
RHEL_MAJOR="${RHEL_MAJOR:-10}"

/usr/bin/dnf-refresh-all.sh

dnf -y install rhel-drivers

/usr/bin/enable-rhel10-nvidia-repos.sh

dnf -y upgrade

# Non-interactive image build: same entry point as on a host (blog + release notes).
if ! rhel-drivers install nvidia; then
	echo "ERROR: rhel-drivers install nvidia failed." >&2
	exit 1
fi

yum_repos_d_writable() {
	touch /etc/yum.repos.d/.nvidia_bootc_write_test 2>/dev/null && rm -f /etc/yum.repos.d/.nvidia_bootc_write_test
}

nvidia_toolkit_repo_url() {
	echo "https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo"
}

if [[ -f /etc/yum.repos.d/nvidia-container-toolkit.repo ]]; then
	echo "Using existing nvidia-container-toolkit.repo (host-mounted)."
elif yum_repos_d_writable; then
	curl -fsSL "$(nvidia_toolkit_repo_url)" -o /etc/yum.repos.d/nvidia-container-toolkit.repo
else
	echo "ERROR: nvidia-container-toolkit.repo missing and /etc/yum.repos.d is not writable." >&2
	echo "On the build host run: sudo RHEL_MAJOR=${RHEL_MAJOR} ./scripts/host/configure-host-nvidia-build-repos.sh" >&2
	exit 1
fi

if [[ "$(arch)" = "aarch64" ]] && [[ "${USE_64K_PAGESIZE}" = "1" ]]; then
	echo "WARN: USE_64K_PAGESIZE=1 on aarch64 is not automated in this OSS Containerfile yet." >&2
fi

cp -a /etc/dnf/dnf.conf{,.tmp} && mv /etc/dnf/dnf.conf{.tmp,}

ARCH="$(uname -m)"
RHOCP_REPO="rhocp-${USHIFT_VER}-for-rhel-${RHEL_MAJOR}-${ARCH}-rpms"
FAST_REPO="fast-datapath-for-rhel-${RHEL_MAJOR}-${ARCH}-rpms"
DNF_OPTS=(
	--best
	--setopt=install_weak_deps=False
	--setopt=tsflags=nodocs
)
_repolist_q=$(dnf repolist --enabled -q 2>/dev/null || true)
if [[ "${_repolist_q}" == *"${RHOCP_REPO}"* ]] && [[ "${_repolist_q}" == *"${FAST_REPO}"* ]]; then
	echo "MicroShift repos already enabled: ${RHOCP_REPO}, ${FAST_REPO}"
else
	DNF_OPTS+=(--enablerepo="${RHOCP_REPO}" --enablerepo="${FAST_REPO}")
fi

dnf "${DNF_OPTS[@]}" install -y python3-dnf-plugin-versionlock

LOCKLIST=""
for _p in kernel-core kernel-modules kernel-modules-core kernel; do
	if _q=$(rpm -q "${_p}" 2>/dev/null); then
		[[ -n "${LOCKLIST}" ]] && LOCKLIST="${LOCKLIST} "
		LOCKLIST="${LOCKLIST}${_q}"
	fi
done
if [[ -n "${LOCKLIST}" ]]; then
	dnf "${DNF_OPTS[@]}" versionlock add ${LOCKLIST}
else
	echo "WARN: no kernel packages to versionlock"
fi

dnf "${DNF_OPTS[@]}" install -y \
	cloud-init \
	firewalld \
	jq \
	microshift \
	microshift-release-info \
	pciutils \
	skopeo \
	nvidia-container-toolkit

if [[ "${DRIVER_TYPE}" != "vgpu" ]]; then
	dnf "${DNF_OPTS[@]}" install -y nvidia-fabricmanager libnvidia-nscq 2>/dev/null || true
fi

KD=$(rpm -qa 'kernel-debug*' || true)
if [[ -n "${KD}" ]]; then
	# shellcheck disable=SC2086
	dnf "${DNF_OPTS[@]}" remove -y ${KD}
fi

dnf "${DNF_OPTS[@]}" clean all

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
ln -sf ../cloud-init.target /usr/lib/systemd/system/default.target.wants/cloud-init.target
systemctl enable nvidia-toolkit-firstboot.service

echo "blacklist nouveau" > /etc/modprobe.d/blacklist_nouveau.conf

if [[ -f /usr/lib/systemd/system/nvidia-fabricmanager.service ]]; then
	sed -i '/\[Unit\]/a ConditionDirectoryNotEmpty=/proc/driver/nvidia-nvswitch/devices' \
		/usr/lib/systemd/system/nvidia-fabricmanager.service
	ln -sf /usr/lib/systemd/system/nvidia-fabricmanager.service \
		/etc/systemd/system/multi-user.target.wants/nvidia-fabricmanager.service
fi

ln -sf /usr/lib/systemd/system/nvidia-persistenced.service \
	/etc/systemd/system/multi-user.target.wants/nvidia-persistenced.service

nvidia-ctk runtime configure --runtime=crio --set-as-default \
	--drop-in-config=/etc/crio/crio.conf.d/99-nvidia.conf

if [[ -f /etc/crio/crio.conf.d/microshift.conf ]]; then
	mv /etc/crio/crio.conf.d/microshift.conf /etc/crio/crio.conf.d/10-microshift.conf
fi
if [[ -f /etc/crio/crio.conf.d/microshift-ovn.conf ]]; then
	mv /etc/crio/crio.conf.d/microshift-ovn.conf /etc/crio/crio.conf.d/11-microshift-ovn.conf
fi

sed -i 's/^runtimes =.*$/runtimes = ["crun", "docker-runc", "runc"]/g' \
	/etc/nvidia-container-runtime/config.toml

setsebool -P container_use_devices on

sed -i "s|__NVDP_IMAGE__|${NVDP_IMAGE}|g" \
	/etc/microshift/manifests.d/nvidia-device-plugin/nvidia-device-plugin.yaml
