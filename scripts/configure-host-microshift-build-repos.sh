#!/usr/bin/bash
# Enable MicroShift OCP + fast-datapath repos on the *build host* so a read-only
# podman mount of /etc/yum.repos.d carries enabled=1 entries (no --enablerepo in the container).
# Requires RHSM + entitlement that includes these repos. USHIFT_VER must match argfile.conf.
set -euo pipefail

: "${USHIFT_VER:?Set USHIFT_VER (e.g. 4.20) — same as image build arg}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "Run as root (sudo)." >&2
	exit 1
fi

ARCH="$(uname -m)"
RHOCP_REPO="rhocp-${USHIFT_VER}-for-rhel-9-${ARCH}-rpms"
FAST_REPO="fast-datapath-for-rhel-9-${ARCH}-rpms"

if ! command -v subscription-manager >/dev/null 2>&1; then
	echo "Host: subscription-manager not found; skipping MicroShift repo enable (container will use --enablerepo)."
	exit 0
fi

echo "Host: enabling ${RHOCP_REPO} and ${FAST_REPO}"
subscription-manager repos --enable="${RHOCP_REPO}" --enable="${FAST_REPO}"
