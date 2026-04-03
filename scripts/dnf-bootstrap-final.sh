#!/usr/bin/bash
# Final bootc stage: full upgrade to latest (including kernel) before layering MicroShift / NVIDIA.
set -euo pipefail
/usr/bin/dnf-refresh-all.sh
