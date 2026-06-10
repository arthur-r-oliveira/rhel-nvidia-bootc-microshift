#!/usr/bin/bash
# Enable MicroShift OCP + fast-datapath repos on the *build host* so a read-only
# podman mount of /etc/yum.repos.d carries enabled=1 entries (no --enablerepo in the container).
# Requires RHSM + entitlement that includes these repos. USHIFT_VER must match argfile.conf.
set -euo pipefail

: "${USHIFT_VER:?Set USHIFT_VER (e.g. 4.20) — same as image build arg}"
RHEL_MAJOR="${RHEL_MAJOR:-9}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "Run as root (sudo)." >&2
	exit 1
fi

ARCH="$(uname -m)"
_repolist_all="$(dnf repolist --enabled -q 2>/dev/null || true)"

if [[ "${_repolist_all}" == *"rhocp-${USHIFT_VER}-el9"* ]]; then
    echo "Using MicroShift EL9 workaround repos"

    RHOCP_REPO="rhocp-${USHIFT_VER}-el9"
    FAST_REPO="fast-datapath-el9"
else
    echo "Using native RHEL${RHEL_MAJOR} MicroShift repos"

    RHOCP_REPO="rhocp-${USHIFT_VER}-for-rhel-${RHEL_MAJOR}-${ARCH}-rpms"
    FAST_REPO="fast-datapath-for-rhel-${RHEL_MAJOR}-${ARCH}-rpms"
fi

RHOCP_REPO="rhocp-${USHIFT_VER}-for-rhel-${RHEL_MAJOR}-${ARCH}-rpms"
FAST_REPO="fast-datapath-for-rhel-${RHEL_MAJOR}-${ARCH}-rpms"

if ! command -v subscription-manager >/dev/null 2>&1; then
	echo "Host: subscription-manager not found; skipping MicroShift repo enable (container will use --enablerepo)."
	exit 0
fi

echo "Host: enabling ${RHOCP_REPO} and ${FAST_REPO}"
if ! subscription-manager repos --enable="${RHOCP_REPO}" --enable="${FAST_REPO}" >/dev/null 2>&1; then
	if [[ "${RHEL_MAJOR}" == "10" ]] && [[ "${USHIFT_VER}" == "4.21" ]]; then
		_WORKAROUND="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/configure-host-microshift-workaround-repos.sh"
		if [[ ! -x "${_WORKAROUND}" ]]; then
			chmod 755 "${_WORKAROUND}"
		fi
		echo "Host: standard RHEL 10 MicroShift repos unavailable; using RHEL 9 workaround repo path."
		"${_WORKAROUND}"
		exit 0
	fi
	echo "Host: failed to enable ${RHOCP_REPO} or ${FAST_REPO} via subscription-manager." >&2
	exit 1
fi
