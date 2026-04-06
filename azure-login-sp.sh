#!/usr/bin/bash
set -euo pipefail
_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${_ROOT}/cloud/azure/azure-login-sp.sh" "$@"
