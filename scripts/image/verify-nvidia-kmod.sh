#!/usr/bin/bash
set -euo pipefail

krel=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}')
karch=$(rpm -q kernel-core --qf '%{ARCH}')
kdir="${krel}.${karch}"
ko="/lib/modules/${kdir}/extra/drivers/video/nvidia/nvidia.ko"
if [ ! -f "${ko}" ]; then
    ko=$(find "/lib/modules/${kdir}" -name nvidia.ko -type f 2>/dev/null | head -1) || true
fi
if [ ! -f "${ko}" ]; then
    echo "FATAL: nvidia.ko missing for kernel ${kdir}"
    find /lib/modules -maxdepth 2 -type d 2>/dev/null || true
    exit 1
fi
# Precompiled RPM from yum-packaging-precompiled-kmod is named kmod-nvidia-<ver>-<kernel>-…, not "kmod-nvidia".
kmod_pkg=$(rpm -qa | grep -E '^kmod-nvidia-[0-9]' | head -1)
if [ -z "${kmod_pkg}" ]; then
    echo "FATAL: no kmod-nvidia-* RPM installed (expected precompiled kmod package)"
    exit 1
fi
rpm -q "${kmod_pkg}" nvidia-driver nvidia-driver-cuda
