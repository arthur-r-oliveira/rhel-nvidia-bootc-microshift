#!/usr/bin/bash
# bootc container lint: scrub /var files, optional /boot debug leftovers, tmpfiles.d, then lint.
set -euo pipefail

# Drop log and cache files first (lint flags non-dir files under /var, not empty logs).
rm -rf /var/lib/containers/cache /root/.local/share/containers/cache
rm -f /var/lib/dnf/history.sqlite /var/lib/dnf/history.sqlite-shm /var/lib/dnf/history.sqlite-wal
rm -rf /var/lib/dnf/modulefailsafe
rm -rf /var/cache/dnf /var/cache/libdnf5
find /var/lib/rhsm -type f -delete 2>/dev/null || true
rm -f /var/lib/unbound/root.key /var/cache/ldconfig/aux-cache
find /var/log -type f -delete 2>/dev/null || true

# If any kernel-debug debris remains, bootc nonempty-boot lint complains.
find /boot -maxdepth 1 -name '*+debug*' -delete 2>/dev/null || true

_var_tmpfiles=/usr/lib/tmpfiles.d/50-nvidia-bootc-var.conf
{
    while IFS= read -r -d '' d; do
        m=$(stat -c '%a' "$d")
        [[ ${#m} -eq 3 ]] && m="0${m}"
        printf 'd %s %s %s %s - -\n' "$d" "$m" "$(stat -c '%U' "$d")" "$(stat -c '%G' "$d")"
    done < <(find /var -type d ! -path /var -print0 | sort -z)
} > "${_var_tmpfiles}"

exec bootc container lint
