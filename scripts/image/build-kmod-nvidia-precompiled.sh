#!/usr/bin/bash
# Self-signed precompiled kmod (no DKMS): full dnf refresh, then rpmbuild for current kernel-core.
set -euo pipefail

: "${DRIVER_VERSION:?DRIVER_VERSION is required}"
: "${BASE_URL:?BASE_URL is required}"
VENDOR="${VENDOR:-undefined}"
RPM_HOST="${RPM_HOST:-${HOSTNAME:-localhost}}"
USE_64K_PAGESIZE="${USE_64K_PAGESIZE:-0}"

/usr/bin/dnf-refresh-all.sh

OS_VERSION_MAJOR=$(grep "^VERSION=" /etc/os-release | cut -d '=' -f 2 | sed 's/"//g' | cut -d '.' -f 1)
BUILD_ARCH="$(arch)"
if [ "$(arch)" = "aarch64" ] && [ "${USE_64K_PAGESIZE}" = "1" ]; then
    BUILD_ARCH+="+64k"
fi
DRIVER_STREAM=$(echo "${DRIVER_VERSION}" | cut -d '.' -f 1)

git clone --depth 1 --single-branch -b "rhel${OS_VERSION_MAJOR}" \
    https://github.com/NVIDIA/yum-packaging-precompiled-kmod
cd yum-packaging-precompiled-kmod
mkdir -p BUILD BUILDROOT RPMS SRPMS SOURCES SPECS
mkdir "nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH}"
curl -sLOf "${BASE_URL}/${DRIVER_VERSION}/NVIDIA-Linux-$(arch)-${DRIVER_VERSION}.run"
sh "./NVIDIA-Linux-$(arch)-${DRIVER_VERSION}.run" --extract-only --target tmp
mv tmp/kernel-open "nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH}/kernel"
tar -cJf "SOURCES/nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH}.tar.xz" \
    "nvidia-kmod-${DRIVER_VERSION}-${BUILD_ARCH}"
mv kmod-nvidia.spec SPECS/
openssl req -x509 -new -nodes -utf8 -sha256 -days 36500 -batch \
    -config /root/x509-configuration.ini \
    -outform DER -out SOURCES/public_key.der \
    -keyout SOURCES/private_key.priv

# Full upgrade again before rpmbuild, then derive kernel macros from *current* kernel-core.
/usr/bin/dnf-refresh-all.sh

KVER=$(rpm -q --qf "%{VERSION}" kernel-core)
KREL=$(rpm -q --qf "%{RELEASE}" kernel-core | sed 's/\.el.\(_.\)*$//')
KDIST=$(rpm -q --qf "%{RELEASE}" kernel-core | awk -F '.' '{ print "."$NF}')

rpmbuild \
    --define "% _arch ${BUILD_ARCH}" \
    --define "%_topdir $(pwd)" \
    --define "debug_package %{nil}" \
    --define "kernel ${KVER}" \
    --define "kernel_release ${KREL}" \
    --define "kernel_dist ${KDIST}" \
    --define "driver ${DRIVER_VERSION}" \
    --define "driver_branch ${DRIVER_STREAM}" \
    --define "vendor ${VENDOR}" \
    --define "_buildhost ${RPM_HOST}" \
    -v -bb SPECS/kmod-nvidia.spec
