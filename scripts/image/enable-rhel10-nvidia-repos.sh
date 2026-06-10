#!/usr/bin/bash
set -euxo pipefail

echo "Skipping repo enablement"
dnf repolist --enabled

exit 0
