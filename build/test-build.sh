#!/usr/bin/bash
set -euo pipefail

# This script lives in build/; repository root (build context) is one level up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ARGFILE="${REPO_ROOT}/argfile.conf"

# Load KEY=value lines into the environment (same keys as podman --build-arg-file).
load_argfile() {
	local line key value
	while IFS= read -r line || [[ -n "${line}" ]]; do
		[[ "${line}" =~ ^[[:space:]]*# ]] && continue
		[[ "${line}" =~ ^[[:space:]]*$ ]] && continue
		key="${line%%=*}"
		value="${line#*=}"
		key="${key%"${key##*[![:space:]]}"}"
		key="${key#"${key%%[![:space:]]*}"}"
		if [[ "${value}" =~ ^\"(.*)\"$ ]]; then
			value="${BASH_REMATCH[1]}"
		fi
		export "${key}=${value}"
	done < "$1"
}

load_argfile "${ARGFILE}"

: "${BASE_IMAGE:?Set BASE_IMAGE in argfile.conf}"
if [[ "${SINGLE_STAGE_BOOTC:-0}" != "1" ]]; then
	: "${BUILDER_IMAGE:?Set BUILDER_IMAGE in argfile.conf (or set SINGLE_STAGE_BOOTC=1 for OSS RHEL 10 single Containerfile)}"
fi

# Optional: pin host subscription to a RHEL minor and EUS BaseOS/AppStream before builds so dnf
# (especially with BUILD_WITH_HOST_RHSM=1) matches rhel9-eus bootc. Ref:
# https://access.redhat.com/articles/rhel-eus#c5
if [[ "${CONFIGURE_BUILD_HOST_EUS:-0}" == "1" ]] && [[ -n "${EUS_RELEASE:-}" ]]; then
	if ! command -v subscription-manager >/dev/null 2>&1; then
		echo "Note: CONFIGURE_BUILD_HOST_EUS=1 but subscription-manager not on PATH; skipping host EUS setup."
	else
		_CFG="${REPO_ROOT}/scripts/host/configure-host-rhsm-eus.sh"
		if [[ ! -x "${_CFG}" ]]; then
			chmod 755 "${_CFG}"
		fi
		echo "Configuring build host RHSM for EUS (EUS_RELEASE=${EUS_RELEASE})…"
		if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
			EUS_RELEASE="${EUS_RELEASE}" "${_CFG}"
		else
			sudo EUS_RELEASE="${EUS_RELEASE}" "${_CFG}"
		fi
	fi
fi

# When /etc/yum.repos.d is bind-mounted read-only (EUS + RHSM), the host supplies .repo files and
# (optionally) enables MicroShift repos in redhat.repo so the container need not use --enablerepo.
if [[ "${BUILD_WITH_HOST_RHSM:-}" == "1" ]]; then
	_MOUNT_YUM=0
	if [[ "${BUILD_WITH_HOST_YUM_REPOS:-}" == "1" ]] || [[ -n "${EUS_RELEASE:-}" ]] || [[ "${SINGLE_STAGE_BOOTC:-0}" == "1" ]]; then
		_MOUNT_YUM=1
	fi
	if [[ "${_MOUNT_YUM}" -eq 1 ]]; then
		if [[ "${CONFIGURE_HOST_NVIDIA_REPOS:-1}" == "1" ]]; then
			_NVR="${REPO_ROOT}/scripts/host/configure-host-nvidia-build-repos.sh"
			if [[ ! -x "${_NVR}" ]]; then
				chmod 755 "${_NVR}"
			fi
			echo "Ensuring NVIDIA CUDA + container-toolkit .repo files on host (for ro yum.repos.d mount)…"
			if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
				RHEL_MAJOR="${RHEL_MAJOR:-9}" "${_NVR}"
			else
				sudo RHEL_MAJOR="${RHEL_MAJOR:-9}" "${_NVR}"
			fi
		fi
		if [[ "${CONFIGURE_HOST_MICROSHIFT_REPOS:-1}" == "1" ]]; then
			_MS="${REPO_ROOT}/scripts/host/configure-host-microshift-build-repos.sh"
			if [[ ! -x "${_MS}" ]]; then
				chmod 755 "${_MS}"
			fi
			echo "Enabling MicroShift rhocp + fast-datapath repos on host (USHIFT_VER=${USHIFT_VER} RHEL_MAJOR=${RHEL_MAJOR:-9})…"
			if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
				USHIFT_VER="${USHIFT_VER}" RHEL_MAJOR="${RHEL_MAJOR:-9}" "${_MS}"
			else
				sudo USHIFT_VER="${USHIFT_VER}" RHEL_MAJOR="${RHEL_MAJOR:-9}" "${_MS}"
			fi
		fi
	fi
fi

# Pull secret for `skopeo copy` during the embed RUN and for registry pulls.
if [[ -f "${REPO_ROOT}/.pull-secret.json" ]]; then
	AUTHFILE="${REPO_ROOT}/.pull-secret.json"
elif [[ -n "${XDG_RUNTIME_DIR:-}" && -f "${XDG_RUNTIME_DIR}/containers/auth.json" ]]; then
	AUTHFILE="${XDG_RUNTIME_DIR}/containers/auth.json"
elif [[ -f "${HOME}/.config/containers/auth.json" ]]; then
	AUTHFILE="${HOME}/.config/containers/auth.json"
else
	echo "No pull secret found. Either:"
	echo "  - Place console.redhat.com pull secret at ${REPO_ROOT}/.pull-secret.json, or"
	echo "  - Run: podman login registry.redhat.io (and nvcr.io if needed for NVDP_IMAGE)"
	exit 1
fi

if ! grep -q registry.redhat.io "${AUTHFILE}" 2>/dev/null; then
	echo "Warning: ${AUTHFILE} has no registry.redhat.io entry; base/MicroShift pulls may fail."
fi

FINAL_IMAGE_TAG="${FINAL_IMAGE_TAG:-microshift-nvidia-bootc-test}"

# Pre-pull base so builder + final share the same resolved layers. Skip with SKIP_PRE_PULL=1.
if [[ -z "${SKIP_PRE_PULL:-}" ]]; then
	echo "Pre-pull BASE_IMAGE: ${BASE_IMAGE}"
	podman pull --authfile "${AUTHFILE}" "${BASE_IMAGE}"
fi

PODMAN_BUILD_PULL="${PODMAN_BUILD_PULL:-newer}"
EXTRA_BUILD_ARGS=(--pull="${PODMAN_BUILD_PULL}")

# Mount options: append `,z` so Podman relabels host paths for the build mount namespace. Without this,
# SELinux often blocks curl/openssl from reading /etc/pki/entitlement/*.pem → Curl (58) PEM Permission denied.
# Set BUILD_RHSM_VOLUME_SELINUX_LABEL=none to use plain :ro (non-SELinux hosts or if you must not relabel).
RHSM_VOL_SUFFIX="ro,z"
if [[ "${BUILD_RHSM_VOLUME_SELINUX_LABEL:-}" == "none" ]]; then
	RHSM_VOL_SUFFIX="ro"
fi
# Entitlement keys: rarely need rw; set BUILD_ENTITLEMENT_VOLUME_RW=1 if openssl still cannot open the key.
ENT_VOL_SUFFIX="${RHSM_VOL_SUFFIX}"
if [[ "${BUILD_ENTITLEMENT_VOLUME_RW:-}" == "1" ]]; then
	if [[ "${RHSM_VOL_SUFFIX}" == "ro,z" ]]; then
		ENT_VOL_SUFFIX="rw,z"
	elif [[ "${RHSM_VOL_SUFFIX}" == "ro" ]]; then
		ENT_VOL_SUFFIX="rw"
	fi
fi

RHSM_VOLUME_ARGS=()
if [[ "${BUILD_WITH_HOST_RHSM:-}" == "1" ]]; then
	RHSM_VOLUME_ARGS+=(--volume "/etc/rhsm:/etc/rhsm:${RHSM_VOL_SUFFIX}")
	RHSM_VOLUME_ARGS+=(--volume "/etc/pki/entitlement:/etc/pki/entitlement:${ENT_VOL_SUFFIX}")
	if [[ "${BUILD_WITH_HOST_YUM_REPOS:-}" == "1" ]]; then
		RHSM_VOLUME_ARGS+=(--volume "/etc/yum.repos.d:/etc/yum.repos.d:${RHSM_VOL_SUFFIX}")
	fi
	# EUS: container dnf must see the same entitlement + repo definitions as the host (KB 6712511).
	if [[ -n "${EUS_RELEASE:-}" ]]; then
		if [[ ! -d /var/lib/rhsm ]]; then
			echo "Warning: EUS_RELEASE is set but /var/lib/rhsm missing on host; subscription-manager in the build may not match the host."
		else
			RHSM_VOLUME_ARGS+=(--volume "/var/lib/rhsm:/var/lib/rhsm:${RHSM_VOL_SUFFIX}")
		fi
		if [[ "${BUILD_WITH_HOST_YUM_REPOS:-}" != "1" ]]; then
			echo "Warning: EUS_RELEASE is set but BUILD_WITH_HOST_YUM_REPOS is not 1; enabling BUILD_WITH_HOST_YUM_REPOS for this build."
			RHSM_VOLUME_ARGS+=(--volume "/etc/yum.repos.d:/etc/yum.repos.d:${RHSM_VOL_SUFFIX}")
		fi
	fi
elif [[ -n "${EUS_RELEASE:-}" ]]; then
	echo "Warning: EUS_RELEASE is set but BUILD_WITH_HOST_RHSM is not 1; kernel-devel for bootc may be missing. Use BUILD_WITH_HOST_RHSM=1." >&2
fi

COMMON_BUILD=(
	"${RHSM_VOLUME_ARGS[@]}"
	"${EXTRA_BUILD_ARGS[@]}"
	--authfile "${AUTHFILE}"
	--build-arg-file "${ARGFILE}"
)

if [[ "${SINGLE_STAGE_BOOTC:-0}" == "1" ]]; then
	echo "SINGLE_STAGE_BOOTC=1: skipping Containerfile.builder (RHEL 10 OSS / rhel-drivers path)."
elif [[ -z "${SKIP_BUILDER:-}" ]]; then
	echo "Building kmod builder image: ${BUILDER_IMAGE}"
	podman build "${COMMON_BUILD[@]}" \
		-f "${REPO_ROOT}/Containerfile.builder" \
		-t "${BUILDER_IMAGE}" \
		"${REPO_ROOT}"
else
	echo "SKIP_BUILDER=1: using existing ${BUILDER_IMAGE}"
fi

echo "Building final bootc image: ${FINAL_IMAGE_TAG}"
podman build "${COMMON_BUILD[@]}" \
	--secret "id=pullsecret,src=${AUTHFILE}" \
	-f "${REPO_ROOT}/Containerfile" \
	-t "${FINAL_IMAGE_TAG}" \
	"${REPO_ROOT}"
