#!/usr/bin/bash
# Upload a fixed VHD to Azure Storage (page blob), create a managed OS disk, and optionally
# a managed image for VM deployment. Intended for artifacts from bootc-image-builder --type vhd.
#
# Downstream reference (VHD handling, Azure deployment context):
#   https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/deploying_rhel_9_on_microsoft_azure/index
# Image builder output layout:
#   https://osbuild.org/docs/bootc/#-image-types
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
	cat <<'EOF'
Usage: push-vhd-to-azure.sh [options]

  Upload a local .vhd to an Azure storage account as a page blob, then create a
  managed disk (and optionally a managed image). This follows the same Azure CLI
  building blocks described for custom RHEL images in Red Hat’s Azure guide:
  https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/deploying_rhel_9_on_microsoft_azure/index

  Prerequisites:
    - Azure CLI (`az`) installed and signed in (`az login`).
    - A resource group and storage account (script can create the container only).
    - VHD must be fixed-size and suitable for Azure (bootc-image-builder --type vhd).

Required options:
  --vhd PATH              Local path to the VHD file (bib often emits bib-output/vpc/disk.vhd
                          or bib-output/vhd/disk.vhd — use find bib-output -name '*.vhd')
  --resource-group NAME   Azure resource group for the disk (and image, if any)
  --storage-account NAME  Storage account name (for blob upload)
  --location REGION       Azure region (e.g. eastus), must match storage account region

Optional:
  -h, --help              Show this help.
  --subscription ID       Azure subscription GUID or name (runs az account set)
  --storage-resource-group NAME   Resource group that holds the storage account (default: same as --resource-group)
  --container NAME        Blob container (default: vhds)
  --blob-name NAME        Blob object name (default: basename of --vhd)
  --disk-name NAME        Managed disk name (default: derived from blob name)
  --image-name NAME       If set, create a managed image from the disk after import
  --sku SKU               Disk SKU: Standard_LRS, Premium_LRS, StandardSSD_LRS, … (default: Standard_LRS)
  --hyper-v-generation V1|V2     VM generation for disk/image (default: V2, typical for RHEL 9 on Azure)
  --dry-run               Print planned az commands and exit
  --upload-only           Only upload the blob; do not create disk or image

Environment (optional defaults):
  AZURE_RESOURCE_GROUP
  AZURE_STORAGE_ACCOUNT
  AZURE_LOCATION
  AZURE_SUBSCRIPTION

Typical workflow:
  1. Build VHD:  ./build-bootc-disk.sh -t vhd -o ./bib-output YOUR_BOOTC_IMAGE
  2. Upload:     ./push-vhd-to-azure.sh --vhd ./bib-output/vpc/disk.vhd \\
                     --resource-group myRg --storage-account mystore --location eastus \\
                     --image-name myBootcRhel9

Notes:
  - Put each long option on one line; do not break between --stor and age-account.
  - If you use \$RESOURCEGROUP, it must be set (export RESOURCEGROUP=my-rg) or the next
    flag is swallowed and you may see "unexpected argument" for the storage account name.
  - Disk import uses a plain blob HTTPS URL plus --source-storage-account-id (no SAS).
    Azure rejects SAS URIs for this path ("cannot be imported from a SAS URI").
    The storage account must be in the same subscription as the managed disk.
  - The script uses the storage account key only for blob upload. Restrict access accordingly.
  - For production, prefer a service principal or managed identity with least
    privilege; extend this script or wrap `az` with your preferred auth pattern.
  - See Red Hat doc sections on converting to fixed VHD and Azure VM settings
    if you need manual steps beyond blob + disk + image.
EOF
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || {
		echo "push-vhd-to-azure.sh: required command not found: $1" >&2
		exit 1
	}
}

# Reject missing values like: --resource-group $RESOURCEGROUP when RESOURCEGROUP is empty
# (next token becomes --storage-account, then nvidiabootc trips "unexpected argument").
check_opt_value() {
	local opt="$1" val="${2:-}"
	if [[ -z "$val" ]]; then
		echo "error: ${opt} needs a value" >&2
		exit 1
	fi
	if [[ "$val" == --* ]]; then
		echo "error: ${opt} is missing a value (next argument is '${val}', another option)." >&2
		if [[ "$opt" == "--resource-group" ]]; then
			echo "hint: if you used \$RESOURCEGROUP, it is unset — export RESOURCEGROUP=<your-rg> or pass the name literally." >&2
		fi
		exit 1
	fi
}

vhd_path=""
resource_group="${AZURE_RESOURCE_GROUP:-}"
storage_account="${AZURE_STORAGE_ACCOUNT:-}"
storage_rg=""
location="${AZURE_LOCATION:-}"
subscription="${AZURE_SUBSCRIPTION:-}"
container="${AZURE_VHD_CONTAINER:-vhds}"
blob_name=""
disk_name=""
image_name=""
sku="${AZURE_DISK_SKU:-Standard_LRS}"
hyperv_gen="V2"
dry_run=0
upload_only=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--vhd)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--vhd" "$2"
		vhd_path="$2"
		shift 2
		;;
	--resource-group)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--resource-group" "$2"
		resource_group="$2"
		shift 2
		;;
	--storage-account)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--storage-account" "$2"
		storage_account="$2"
		shift 2
		;;
	--storage-resource-group)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--storage-resource-group" "$2"
		storage_rg="$2"
		shift 2
		;;
	--location)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--location" "$2"
		location="$2"
		shift 2
		;;
	--subscription)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--subscription" "$2"
		subscription="$2"
		shift 2
		;;
	--container)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--container" "$2"
		container="$2"
		shift 2
		;;
	--blob-name)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--blob-name" "$2"
		blob_name="$2"
		shift 2
		;;
	--disk-name)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--disk-name" "$2"
		disk_name="$2"
		shift 2
		;;
	--image-name)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--image-name" "$2"
		image_name="$2"
		shift 2
		;;
	--sku)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--sku" "$2"
		sku="$2"
		shift 2
		;;
	--hyper-v-generation)
		[[ $# -ge 2 ]] || { echo "error: $1 needs a value" >&2; exit 1; }
		check_opt_value "--hyper-v-generation" "$2"
		hyperv_gen="$2"
		shift 2
		;;
	--dry-run)
		dry_run=1
		shift
		;;
	--upload-only)
		upload_only=1
		shift
		;;
	-*)
		echo "error: unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	*)
		echo "error: unexpected argument: $1" >&2
		usage >&2
		exit 1
		;;
	esac
done

[[ -n "$vhd_path" ]] || { echo "error: --vhd is required" >&2; usage >&2; exit 1; }
[[ -n "$resource_group" ]] || { echo "error: --resource-group is required" >&2; usage >&2; exit 1; }
[[ -n "$storage_account" ]] || { echo "error: --storage-account is required" >&2; usage >&2; exit 1; }
[[ -n "$location" ]] || { echo "error: --location is required" >&2; usage >&2; exit 1; }

if [[ "$hyperv_gen" != "V1" && "$hyperv_gen" != "V2" ]]; then
	echo "error: --hyper-v-generation must be V1 or V2" >&2
	exit 1
fi

if [[ ! -f "$vhd_path" ]]; then
	if [[ "$dry_run" -eq 1 ]]; then
		echo "push-vhd-to-azure.sh: warning: VHD not found (dry-run): $vhd_path" >&2
	else
		echo "error: VHD file not found: $vhd_path" >&2
		exit 1
	fi
elif [[ -f "$vhd_path" ]]; then
	vhd_path="$(cd "$(dirname "$vhd_path")" && pwd)/$(basename "$vhd_path")"
fi

[[ -z "$blob_name" ]] && blob_name="$(basename "$vhd_path")"
[[ -z "$disk_name" ]] && disk_name="${blob_name%.vhd}"
[[ -z "$disk_name" ]] && disk_name="$blob_name"
disk_name="${disk_name//[^a-zA-Z0-9_-]/-}"

[[ -n "$storage_rg" ]] || storage_rg="$resource_group"

if [[ "$dry_run" -eq 0 ]]; then
	require_cmd az
	if ! az account show &>/dev/null; then
		echo "push-vhd-to-azure.sh: not logged in; run: az login" >&2
		exit 1
	fi
fi

if [[ -n "$subscription" && "$dry_run" -eq 0 ]]; then
	az account set --subscription "$subscription"
fi

run() {
	if [[ "$dry_run" -eq 1 ]]; then
		printf '+'
		printf ' %q' "$@"
		printf '\n'
		return 0
	fi
	"$@"
}

echo "Using VHD: $vhd_path"
echo "Storage account: $storage_account (RG: $storage_rg), container: $container, blob: $blob_name"

# Storage account key (same pattern as many Azure + RHEL lab flows).
if [[ "$dry_run" -eq 1 ]]; then
	ACCOUNT_KEY="<storage-account-key>"
	STORAGE_ACCOUNT_ID="/subscriptions/<sub>/resourceGroups/${storage_rg}/providers/Microsoft.Storage/storageAccounts/${storage_account}"
else
	ACCOUNT_KEY="$(
		az storage account keys list \
			--resource-group "$storage_rg" \
			--account-name "$storage_account" \
			--query '[0].value' \
			-o tsv
	)"
	STORAGE_ACCOUNT_ID="$(
		az storage account show \
			--resource-group "$storage_rg" \
			--name "$storage_account" \
			--query id \
			-o tsv
	)"
fi

if [[ "$dry_run" -eq 1 ]]; then
	run az storage container create \
		--name "$container" \
		--account-name "$storage_account" \
		--account-key "$ACCOUNT_KEY"
else
	az storage container create \
		--name "$container" \
		--account-name "$storage_account" \
		--account-key "$ACCOUNT_KEY" \
		2>/dev/null || true
fi

run az storage blob upload \
	--file "$vhd_path" \
	--container-name "$container" \
	--name "$blob_name" \
	--type page \
	--overwrite \
	--account-name "$storage_account" \
	--account-key "$ACCOUNT_KEY"

if [[ "$upload_only" -eq 1 ]]; then
	if [[ "$dry_run" -eq 1 ]]; then
		echo "[dry-run] Would finish after blob upload (--upload-only). Blob: $blob_name"
	else
		echo "Upload complete (--upload-only). Blob: $blob_name"
	fi
	exit 0
fi

# Plain blob URL (no SAS). Azure requires --source-storage-account-id for this import path.
blob_url="https://${storage_account}.blob.core.windows.net/${container}/${blob_name}"

run az disk create \
	--resource-group "$resource_group" \
	--name "$disk_name" \
	--location "$location" \
	--source "$blob_url" \
	--source-storage-account-id "$STORAGE_ACCOUNT_ID" \
	--sku "$sku" \
	--os-type Linux \
	--hyper-v-generation "$hyperv_gen"

if [[ -z "$image_name" ]]; then
	if [[ "$dry_run" -eq 1 ]]; then
		echo "[dry-run] Would create managed disk: $disk_name (resource group: $resource_group)"
	else
		echo "Managed disk created: $disk_name (resource group: $resource_group)"
		echo "To create a VM from this disk, use the Azure portal or 'az vm create' with --attach-os-disk, or pass --image-name next time."
	fi
	exit 0
fi

if [[ "$dry_run" -eq 1 ]]; then
	disk_id="/subscriptions/.../resourceGroups/${resource_group}/providers/Microsoft.Compute/disks/${disk_name}"
else
	disk_id="$(az disk show --resource-group "$resource_group" --name "$disk_name" --query id -o tsv)"
fi

run az image create \
	--resource-group "$resource_group" \
	--name "$image_name" \
	--source "$disk_id" \
	--os-type Linux \
	--hyper-v-generation "$hyperv_gen"

if [[ "$dry_run" -eq 1 ]]; then
	echo "[dry-run] Would create managed image: $image_name (resource group: $resource_group)"
else
	echo "Managed image created: $image_name (resource group: $resource_group)"
	echo "Create a VM with: az vm create ... --image \"$image_name\" (see Red Hat Azure deployment guide)."
fi
