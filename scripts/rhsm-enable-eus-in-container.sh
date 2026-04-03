#!/usr/bin/bash
# Align container dnf with RHEL EUS BaseOS/AppStream so kernel-devel matches bootc kernel-core.
# Host-only repo toggles are invisible here unless you mount /etc/yum.repos.d and /var/lib/rhsm (see test-build.sh).
# Ref: https://access.redhat.com/solutions/6712511 https://access.redhat.com/articles/rhel-eus#c5
set -euo pipefail

[[ -n "${EUS_RELEASE:-}" ]] || exit 0

if ! command -v subscription-manager >/dev/null 2>&1; then
	echo "ERROR: EUS_RELEASE=${EUS_RELEASE} but subscription-manager not installed in this image." >&2
	exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
	x86_64) PREFIX="rhel-9-for-x86_64" ;;
	aarch64) PREFIX="rhel-9-for-aarch64" ;;
	ppc64le) PREFIX="rhel-9-for-ppc64le" ;;
	s390x) PREFIX="rhel-9-for-s390x" ;;
	*)
		echo "Unsupported arch for RHEL 9 EUS repo IDs: ${ARCH}" >&2
		exit 1
		;;
esac

BASE_STD="${PREFIX}-baseos-rpms"
APP_STD="${PREFIX}-appstream-rpms"
BASE_EUS="${PREFIX}-baseos-eus-rpms"
APP_EUS="${PREFIX}-appstream-eus-rpms"

echo "RHSM (container): release --set=${EUS_RELEASE}; prefer ${BASE_EUS} + ${APP_EUS}"
SM_ERR=0
subscription-manager release --set="${EUS_RELEASE}" || SM_ERR=1
subscription-manager repos --disable="${BASE_STD}" 2>/dev/null || true
subscription-manager repos --disable="${APP_STD}" 2>/dev/null || true
subscription-manager repos --enable="${BASE_EUS}" --enable="${APP_EUS}" || SM_ERR=1
subscription-manager refresh || SM_ERR=1

if [[ "${SM_ERR}" -ne 0 ]]; then
	if dnf repolist --enabled 2>/dev/null | grep -qiE 'eus|extended'; then
		echo "RHSM (container): subscription-manager reported errors but dnf already has an EUS-related repo enabled (typical with mounted /etc/yum.repos.d/redhat.repo)."
	else
		echo "ERROR: Could not enable EUS via subscription-manager and no EUS repo is enabled." >&2
		echo "Mount host /etc/yum.repos.d (with redhat.repo after host EUS setup), /var/lib/rhsm, /etc/rhsm, and /etc/pki/entitlement — see README / https://access.redhat.com/solutions/6712511" >&2
		exit 1
	fi
fi
