#!/usr/bin/bash
# Sign in to Azure CLI with a service principal using credentials from a local file.
# The file must not be committed (see .env.azure.example). Prefer chmod 600 on .env.azure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${AZURE_ENV_FILE:-${SCRIPT_DIR}/.env.azure}"

usage() {
	cat <<EOF
Usage: azure-login-sp.sh

  Sources ${ENV_FILE} (or path in AZURE_ENV_FILE), then runs:
    az login --service-principal ...
    az account set --subscription ...   (if AZURE_SUBSCRIPTION is set)

  Copy cloud/azure/.env.azure.example to cloud/azure/.env.azure and set:
    AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, AZURE_TENANT_ID
  Optional: AZURE_SUBSCRIPTION (subscription GUID or name)

  Environment:
    AZURE_ENV_FILE   Override path to the env file (default: cloud/azure/.env.azure)
EOF
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
	usage
	exit 0
fi

if ! command -v az >/dev/null 2>&1; then
	echo "error: Azure CLI (az) not found" >&2
	exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
	echo "error: missing env file: $ENV_FILE" >&2
	echo "hint: cp ${SCRIPT_DIR}/.env.azure.example ${SCRIPT_DIR}/.env.azure && edit; chmod 600 ${SCRIPT_DIR}/.env.azure" >&2
	echo "hint: or set AZURE_ENV_FILE to your file path" >&2
	exit 1
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

if [[ -z "${AZURE_CLIENT_ID:-}" || -z "${AZURE_CLIENT_SECRET:-}" || -z "${AZURE_TENANT_ID:-}" ]]; then
	echo "error: AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, and AZURE_TENANT_ID must be set in ${ENV_FILE}" >&2
	exit 1
fi

az login --service-principal \
	-u "$AZURE_CLIENT_ID" \
	-p "$AZURE_CLIENT_SECRET" \
	--tenant "$AZURE_TENANT_ID"

if [[ -n "${AZURE_SUBSCRIPTION:-}" ]]; then
	az account set --subscription "$AZURE_SUBSCRIPTION"
fi

echo "Signed in. Active subscription:"
az account show --query "{name:name, id:id, user:user.name}" -o jsonc 2>/dev/null || az account show -o table
