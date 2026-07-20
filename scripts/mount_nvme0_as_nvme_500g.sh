#!/usr/bin/env bash
#
# Mount /dev/nvme0n1p1 persistently at /mnt/nvme_500g.

set -euo pipefail

TARGET=${TARGET:-/mnt/nvme_500g}
NEW_UUID=${NEW_UUID:-4501ba70-a2c4-45df-94d9-a735cf610508}
NEW_DEV=${NEW_DEV:-/dev/nvme0n1p1}
FSTAB=${FSTAB:-/etc/fstab}

if [ "${EUID}" -ne 0 ]; then
        printf 'run with sudo/root; this edits %s and remounts %s\n' "${FSTAB}" "${TARGET}" >&2
        exit 1
fi

if [ ! -b "${NEW_DEV}" ]; then
        printf 'missing block device: %s\n' "${NEW_DEV}" >&2
        exit 1
fi

actual_uuid=$(blkid -s UUID -o value "${NEW_DEV}" 2>/dev/null || true)
if [ "${actual_uuid}" != "${NEW_UUID}" ]; then
        printf 'unexpected UUID for %s: %s\n' "${NEW_DEV}" "${actual_uuid:-missing}" >&2
        printf 'expected UUID: %s\n' "${NEW_UUID}" >&2
        exit 1
fi

mkdir -p "${TARGET}"

current_source=$(findmnt -rn -o SOURCE --target "${TARGET}" 2>/dev/null || true)
if [ -n "${current_source}" ] && [ "${current_source}" != "${NEW_DEV}" ]; then
        if fuser -m "${TARGET}" >/dev/null 2>&1; then
                printf '%s is busy; stop users of the current mount first\n' "${TARGET}" >&2
                fuser -vm "${TARGET}" >&2 || true
                exit 1
        fi
        umount "${TARGET}"
fi

backup=${FSTAB}.cofunc-backup-$(date -u +%Y%m%d_%H%M%S)
cp -a "${FSTAB}" "${backup}"

tmp=$(mktemp)
awk -v target="${TARGET}" '
        /^[[:space:]]*#/ || NF < 2 {
                print
                next
        }
        $2 == target {
                print "# replaced by mount_nvme0_as_nvme_500g.sh: " $0
                next
        }
        {
                print
        }
' "${FSTAB}" >"${tmp}"
printf 'UUID=%s %s ext4 defaults 0 2\n' "${NEW_UUID}" "${TARGET}" >>"${tmp}"
install -m 0644 "${tmp}" "${FSTAB}"
rm -f "${tmp}"

systemctl daemon-reload 2>/dev/null || true

if findmnt -rn --target "${TARGET}" >/dev/null 2>&1; then
        mount -o remount "${TARGET}"
else
        mount "${TARGET}"
fi

findmnt "${TARGET}"
printf 'fstab_backup=%s\n' "${backup}"
