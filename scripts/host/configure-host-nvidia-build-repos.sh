#!/usr/bin/bash
# Install public NVIDIA .repo files on the *build host* so a read-only podman mount of
# /etc/yum.repos.d still provides CUDA + libnvidia-container during image build.
# Ref: https://nvidia.github.io/cloud-native-docs/review/pr-358/edge/latest/nvidia-gpu-with-device-edge.html
set -euo pipefail

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	echo "Run as root (sudo)." >&2
	exit 1
fi

RHEL_MAJOR="${RHEL_MAJOR:-9}"

nvidia_cuda_repo_url() {
	local maj="${1:?}"
	case "$(uname -m)" in
		x86_64)
			if [[ "${maj}" == "10" ]]; then
				echo "https://developer.download.nvidia.com/compute/cuda/repos/rhel10/x86_64/cuda-rhel10.repo"
			else
				echo "https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo"
			fi
			;;
		aarch64)
			if [[ "${maj}" == "10" ]]; then
				echo "https://developer.download.nvidia.com/compute/cuda/repos/rhel10/sbsa/cuda-rhel10.repo"
			else
				echo "https://developer.download.nvidia.com/compute/cuda/repos/rhel9/sbsa/cuda-rhel9.repo"
			fi
			;;
		*) echo "Unsupported arch $(uname -m)" >&2; exit 1 ;;
	esac
}

CUDA_URL="$(nvidia_cuda_repo_url "${RHEL_MAJOR}")"
_cuda_file="cuda-rhel${RHEL_MAJOR}.repo"
if [[ -f "/etc/yum.repos.d/${_cuda_file}" ]]; then
	echo "Host: /etc/yum.repos.d/${_cuda_file} already present."
else
	echo "Host: adding CUDA repo (${CUDA_URL})"
	curl -fsSL "${CUDA_URL}" -o "/etc/yum.repos.d/${_cuda_file}"
fi

TOOLKIT_REPO=/etc/yum.repos.d/nvidia-container-toolkit.repo
if [[ -f "${TOOLKIT_REPO}" ]]; then
	echo "Host: ${TOOLKIT_REPO} already present."
else
	echo "Host: installing NVIDIA Container Toolkit stable repo"
	curl -sL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
		-o "${TOOLKIT_REPO}"
fi

if [[ "$(uname -m)" == "aarch64" ]]; then
	mkdir -p /etc/dnf/vars
	echo "sbsa" > /etc/dnf/vars/cudaarch
else
	mkdir -p /etc/dnf/vars
	uname -m > /etc/dnf/vars/cudaarch
fi

echo "Host NVIDIA build repos ready (mount /etc/yum.repos.d read-only into podman build)."
