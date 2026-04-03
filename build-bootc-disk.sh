#!/usr/bin/bash
# Build disk/installer artifacts from a bootc container using bootc-image-builder.
# Reference: https://osbuild.org/docs/bootc/#-image-types
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Image types supported by bootc-image-builder (--type may be repeated).
readonly VALID_TYPES=(
	ami
	qcow2
	vmdk
	bootc-installer
	anaconda-iso
	raw
	vhd
	gce
	pxe-tar-xz
)

usage() {
	cat <<'EOF'
Usage: build-bootc-disk.sh [options] <bootc-container-image>

  Build disk or cloud artifacts from a bootc OCI image via bootc-image-builder
  (podman run --privileged). See:
  https://osbuild.org/docs/bootc/#-image-types

  <bootc-container-image>  e.g. localhost/microshift-nvidia-bootc-test:latest

Options:
  -h, --help              Show this help.
  -t, --type TYPE         Output type (repeat for multiple). Default: qcow2
  -o, --output DIR        Artifact output directory. Default: ./bib-output
  -b, --bib-image REF     bootc-image-builder container. Default:
                            quay.io/centos-bootc/bootc-image-builder:latest
  -c, --config FILE       Blueprint/TOML (or JSON) mounted at /config.toml
  --rootfs TYPE           Root filesystem: ext4, xfs, or btrfs (optional)
  --target-arch ARCH      Target CPU arch (e.g. amd64, arm64); experimental
  --no-use-librepo        Do not pass --use-librepo=True (default: pass it)
  --dry-run               Print the podman command and exit
  --                      End of script options; next arg is image ref, then bib args

Supported --type values (same as upstream):
  ami              Amazon Machine Image (optional AWS upload flags; see docs)
  qcow2            QEMU/KVM (default)
  vmdk             VMware / vSphere
  bootc-installer  Installer ISO based on the bootc image
  anaconda-iso     Unattended Anaconda installer (RPM-based)
  raw              Raw disk image
  vhd              Virtual PC / Hyper-V style VHD
  gce              Google Compute Engine
  pxe-tar-xz       PXE boot tarball (image must include dracut-live, etc.)

Notes:
  - Run as root (e.g. sudo); the script exits if EUID is not 0 unless you use --dry-run.
  - Run on SELinux hosts with osbuild SELinux policies (e.g. osbuild-selinux).
  - Rootful podman is typical; mount host storage at /var/lib/containers/storage.
  - For --type ami, see upstream AWS flags (--aws-ami-name, --aws-bucket, --aws-region).
  - For pxe-tar-xz, the source container must satisfy extra package requirements per docs.

  Use  --  IMAGE [bib-flags...]  when forwarding dashed options to bootc-image-builder
  (so this script does not consume them). Bib flags are placed before the source image
  on the command line, as in the upstream examples (e.g. --type ami --aws-bucket … IMAGE).

Environment:
  BIB_OUTPUT_DIR      Default output directory (same as -o)
  BIB_BUILDER_IMAGE   Default bib container (same as -b)

Examples:
  ./build-bootc-disk.sh -t qcow2 localhost/microshift-nvidia-bootc-test:latest
  ./build-bootc-disk.sh -t qcow2 -t raw -o ./out localhost/microshift-nvidia-bootc-test:latest
  ./build-bootc-disk.sh -t bootc-installer -c ./bib-config.toml \\
      localhost/microshift-nvidia-bootc-test:latest
  ./build-bootc-disk.sh -t ami -- localhost/foo:latest \\
      --aws-ami-name my-ami --aws-bucket my-bucket --aws-region us-east-1
EOF
}

is_valid_type() {
	local t="$1"
	local x
	for x in "${VALID_TYPES[@]}"; do
		[[ "$x" == "$t" ]] && return 0
	done
	return 1
}

types=()
output_dir="${BIB_OUTPUT_DIR:-${SCRIPT_DIR}/bib-output}"
bib_image="${BIB_BUILDER_IMAGE:-registry.redhat.io/rhel9/bootc-image-builder:latest}"
config_file=""
rootfs=""
target_arch=""
use_librepo=1
dry_run=0
imgref=""
extra_bib=()

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-t | --type)
		[[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
		types+=("$2")
		shift 2
		;;
	-o | --output)
		[[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
		output_dir="$2"
		shift 2
		;;
	-b | --bib-image)
		[[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
		bib_image="$2"
		shift 2
		;;
	-c | --config)
		[[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
		config_file="$2"
		shift 2
		;;
	--rootfs)
		[[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
		rootfs="$2"
		shift 2
		;;
	--target-arch)
		[[ $# -ge 2 ]] || { echo "error: $1 requires an argument" >&2; exit 1; }
		target_arch="$2"
		shift 2
		;;
	--no-use-librepo)
		use_librepo=0
		shift
		;;
	--dry-run)
		dry_run=1
		shift
		;;
	--)
		shift
		if [[ $# -gt 0 ]]; then
			imgref="$1"
			shift
			extra_bib+=("$@")
		fi
		break
		;;
	-*)
		echo "error: unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	*)
		if [[ -z "$imgref" ]]; then
			imgref="$1"
		else
			extra_bib+=("$1")
		fi
		shift
		;;
	esac
done

if [[ ${#types[@]} -eq 0 ]]; then
	types=(qcow2)
fi

bad=0
for t in "${types[@]}"; do
	if ! is_valid_type "$t"; then
		echo "error: unsupported type '$t'. Valid: ${VALID_TYPES[*]}" >&2
		bad=1
	fi
done
[[ "$bad" -eq 0 ]] || exit 1

if [[ -z "$imgref" ]]; then
	echo "error: bootc container image reference is required." >&2
	usage >&2
	exit 1
fi

if [[ -n "$config_file" && ! -f "$config_file" ]]; then
	echo "error: config file not found: $config_file" >&2
	exit 1
fi

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"

podman_args=(
	--rm
	-it
	--privileged
	--pull=newer
	--security-opt
	label=type:unconfined_t
	-v "${output_dir}:/output"
	-v /var/lib/containers/storage:/var/lib/containers/storage
)

if [[ -n "$config_file" ]]; then
	_cfg_dir="$(cd "$(dirname "$config_file")" && pwd)"
	podman_args+=(-v "${_cfg_dir}/$(basename "$config_file"):/config.toml:ro")
fi

bib_args=()

for t in "${types[@]}"; do
	bib_args+=(--type "$t")
done

if [[ -n "$rootfs" ]]; then
	bib_args+=(--rootfs "$rootfs")
fi

if [[ -n "$target_arch" ]]; then
	bib_args+=(--target-arch "$target_arch")
fi

if [[ "$use_librepo" -eq 1 ]]; then
	bib_args+=(--use-librepo=True)
fi

if [[ "$dry_run" -eq 0 ]]; then
	_euid="${EUID:-$(id -u)}"
	if [[ "$_euid" -ne 0 ]]; then
		echo "build-bootc-disk.sh: must run as root (bootc-image-builder needs privileged podman + host storage)." >&2
		echo "Example: sudo $0 [options] IMAGE" >&2
		exit 1
	fi
fi

if [[ "$dry_run" -eq 1 ]]; then
	printf '%q ' podman run "${podman_args[@]}" "$bib_image" "${bib_args[@]}" "${extra_bib[@]}" "$imgref"
	printf '\n'
	exit 0
fi

exec podman run "${podman_args[@]}" "$bib_image" "${bib_args[@]}" "${extra_bib[@]}" "$imgref"
