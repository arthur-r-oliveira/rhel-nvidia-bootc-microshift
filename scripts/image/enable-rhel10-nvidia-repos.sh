#!/usr/bin/bash
# Enable RHEL 10 Supplementary + Extensions so kmod-nvidia-open and nvidia-driver resolve
# (same channels as https://docs.redhat.com/.../ai-accelerator-driver-availability and rhel-drivers(8)).
# Supports both CDN repo IDs (subscription-manager) and Azure RHUI names from lab transcripts.
set -euo pipefail

ARCH="$(uname -m)"

try_sm_enable() {
	if ! command -v subscription-manager >/dev/null 2>&1; then
		return 1
	fi
	local sup="rhel-10-for-${ARCH}-supplementary-rpms"
	local ext="rhel-10-for-${ARCH}-extensions-rpms"
	subscription-manager repos --enable="${sup}" --enable="${ext}" 2>/dev/null && return 0
	return 1
}

dnf -y install dnf-plugins-core

try_sm_enable || true

repo_ids_sup=(
	"rhel-10-for-${ARCH}-supplementary-rpms"
	"rhel-10-supplementary-rhui-rpms"
)
repo_ids_ext=(
	"rhel-10-for-${ARCH}-extensions-rpms"
	"rhel-10-extensions-rhui-rpms"
)

repo_list_has() {
	local rid=$1
	dnf repolist all -q 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${rid}"
}

enable_first_match() {
	local rid
	for rid in "$@"; do
		if repo_list_has "${rid}"; then
			dnf config-manager --set-enabled "${rid}"
			echo "enabled repo: ${rid}"
			return 0
		fi
	done
	return 1
}

enable_first_match "${repo_ids_sup[@]}" || {
	echo "ERROR: could not enable a RHEL 10 Supplementary repo (tried: ${repo_ids_sup[*]})." >&2
	echo "Mount host RHSM + /etc/yum.repos.d or enable repos on the build host." >&2
	exit 1
}
enable_first_match "${repo_ids_ext[@]}" || {
	echo "ERROR: could not enable a RHEL 10 Extensions repo (tried: ${repo_ids_ext[*]})." >&2
	exit 1
}

dnf clean all
