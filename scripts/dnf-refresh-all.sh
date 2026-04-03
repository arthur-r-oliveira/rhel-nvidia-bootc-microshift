#!/usr/bin/bash
# Full distro refresh: releasever, bootc dnf workaround, upgrade all packages (including kernel*), clean metadata.
set -euo pipefail

if [[ -n "${EUS_RELEASE:-}" ]] && [[ -x /usr/bin/rhsm-enable-eus-in-container.sh ]]; then
	/usr/bin/rhsm-enable-eus-in-container.sh
fi

. /etc/os-release
echo "${VERSION_ID}" > /etc/dnf/vars/releasever
cp -a /etc/dnf/dnf.conf{,.tmp} && mv /etc/dnf/dnf.conf{.tmp,}
dnf -y upgrade
dnf clean all
