#!/usr/bin/bash
# Create a MicroShift 4.21 RHEL 10 workaround repo file using the RHEL 9 distribution path.
# This is useful when `rhocp-4.21-for-rhel-10-*` / `fast-datapath-for-rhel-10-*` are not yet available.
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
fi

: "${USHIFT_VER:?Set USHIFT_VER (e.g. 4.21)}"
RHEL_MAJOR="${RHEL_MAJOR:-10}"

if [[ "${RHEL_MAJOR}" != "10" ]] || [[ "${USHIFT_VER}" != "4.21" ]]; then
    echo "This workaround is intended for RHEL 10 / MicroShift 4.21 only." >&2
    exit 1
fi

ARCH="$(uname -m)"
case "${ARCH}" in
    x86_64) ARCH_PATH="x86_64" ;;
    aarch64) ARCH_PATH="aarch64" ;;
    *)
        echo "Unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

shopt -s nullglob
entitlement_pems=(/etc/pki/entitlement/[0-9]*.pem)
entitlement_keys=(/etc/pki/entitlement/[0-9]*-key.pem)
shopt -u nullglob

CERT=""
for pem in "${entitlement_pems[@]:-}"; do
    [[ "${pem}" =~ -key\.pem$ ]] && continue
    CERT="${pem}"
    break
done
KEY="${entitlement_keys[0]:-}"

if [[ -z "${CERT}" ]]; then
    echo "No entitlement certificate found in /etc/pki/entitlement." >&2
    exit 1
fi
if [[ -z "${KEY}" ]]; then
    echo "No entitlement key found in /etc/pki/entitlement." >&2
    exit 1
fi

cat > /etc/yum.repos.d/microshift-workaround.repo <<EOF
[rhocp-${USHIFT_VER}-el9]
name=MicroShift ${USHIFT_VER} Workaround (RHEL 9 Path)
baseurl=https://cdn.redhat.com/content/dist/layered/rhel9/${ARCH_PATH}/rhocp/${USHIFT_VER}/os
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
sslverify=1
sslcacert=/etc/rhsm/ca/redhat-uep.pem
sslclientcert=${CERT}
sslclientkey=${KEY}

[fast-datapath-el9]
name=Fast Datapath Workaround (RHEL 9 Path)
baseurl=https://cdn.redhat.com/content/dist/layered/rhel9/${ARCH_PATH}/fast-datapath/os
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
sslverify=1
sslcacert=/etc/rhsm/ca/redhat-uep.pem
sslclientcert=${CERT}
sslclientkey=${KEY}
EOF

echo "Host: wrote /etc/yum.repos.d/microshift-workaround.repo using RHEL 9 path."
