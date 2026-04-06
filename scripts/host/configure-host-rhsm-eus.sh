#!/usr/bin/bash
# Pin RHEL minor release and prefer EUS BaseOS/AppStream on the *build host* so dnf inside
# podman build sees EUS content when using host RHSM (see BUILD_WITH_HOST_RHSM in build/test-build.sh).
# Ref: https://access.redhat.com/articles/rhel-eus#c5
set -euo pipefail

: "${EUS_RELEASE:?EUS_RELEASE is required (e.g. 9.6)}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "This script must run as root (subscription-manager)." >&2
	exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
	x86_64) PREFIX="rhel-9-for-x86_64" ;;
	aarch64) PREFIX="rhel-9-for-aarch64" ;;
	ppc64le) PREFIX="rhel-9-for-ppc64le" ;;
	s390x) PREFIX="rhel-9-for-s390x" ;;
	*)
		echo "Unsupported architecture for RHEL 9 EUS repo IDs: ${ARCH}" >&2
		exit 1
		;;
esac

BASE_STD="${PREFIX}-baseos-rpms"
APP_STD="${PREFIX}-appstream-rpms"
BASE_EUS="${PREFIX}-baseos-eus-rpms"
APP_EUS="${PREFIX}-appstream-eus-rpms"

echo "RHSM: release --set=${EUS_RELEASE}"
subscription-manager release --set="${EUS_RELEASE}"

echo "RHSM: disable standard BaseOS/AppStream (mutually exclusive with EUS per Red Hat), enable EUS repos"
subscription-manager repos --disable="${BASE_STD}" 2>/dev/null || true
subscription-manager repos --disable="${APP_STD}" 2>/dev/null || true
subscription-manager repos --enable="${BASE_EUS}" --enable="${APP_EUS}"

subscription-manager refresh
echo "RHSM EUS configuration applied (${BASE_EUS}, ${APP_EUS}, release ${EUS_RELEASE})."
