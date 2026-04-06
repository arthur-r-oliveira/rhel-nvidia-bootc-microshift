#!/usr/bin/bash
set -euo pipefail
_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${_ROOT}/build/build-bootc-disk.sh" "$@"
