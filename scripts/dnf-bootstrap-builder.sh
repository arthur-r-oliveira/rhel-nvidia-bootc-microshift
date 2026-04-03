#!/usr/bin/bash
# Toolchain image on BASE_IMAGE: full upgrades, kernel-devel matching running kernel, repeat after installs.
# Pattern: https://github.com/coreos/fedora-bootc-nvidia/blob/main/scripts/builder.sh
set -euo pipefail

ensure_kernel_devel() {
	local kdev="kernel-devel-$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}')"
	if rpm -q "${kdev}" &>/dev/null; then
		return 0
	fi
	if dnf -y install "${kdev}"; then
		return 0
	fi
	echo "ERROR: ${kdev} is not available from enabled repos." >&2
	echo "For rhel9-eus bootc kernels, enable EUS in the build: set EUS_RELEASE in argfile.conf, run configure-host-rhsm-eus.sh on the host, and build with BUILD_WITH_HOST_RHSM=1 (see README)." >&2
	echo "Ref: https://access.redhat.com/solutions/6712511" >&2
	exit 1
}

/usr/bin/dnf-refresh-all.sh
ensure_kernel_devel

dnf -y install \
    rpm-build \
    rpmdevtools \
    gcc \
    make \
    git \
    openssl \
    curl \
    elfutils-libelf-devel \
    binutils

/usr/bin/dnf-refresh-all.sh
ensure_kernel_devel
