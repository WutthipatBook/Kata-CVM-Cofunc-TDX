#!/usr/bin/env bash
#
# Install the rebuilt CoFunc KVM modules for the currently running host kernel.

set -euo pipefail

BUILD_DIR=${BUILD_DIR:-/mnt/nvme_500g/cofunc_tdx_artifact/build/kernel-ubuntu-6.19-tdx}
KERNEL_REL=$(uname -r)
MODULE_ROOT=/lib/modules/${KERNEL_REL}
BACKUP_ROOT=${BACKUP_ROOT:-/var/tmp/cofunc-kvm-module-backup}

SRC_IRQBYPASS=${BUILD_DIR}/virt/lib/irqbypass.ko
SRC_KVM=${BUILD_DIR}/arch/x86/kvm/kvm.ko
SRC_KVM_INTEL=${BUILD_DIR}/arch/x86/kvm/kvm-intel.ko

DST_IRQBYPASS=${MODULE_ROOT}/kernel/virt/lib/irqbypass.ko
DST_KVM=${MODULE_ROOT}/kernel/arch/x86/kvm/kvm.ko
DST_KVM_INTEL=${MODULE_ROOT}/kernel/arch/x86/kvm/kvm-intel.ko

need_file() {
        if [ ! -f "$1" ]; then
                printf 'missing required file: %s\n' "$1" >&2
                exit 1
        fi
}

if [ "${EUID}" -ne 0 ]; then
        printf 'run with sudo/root; this must write under %s and reload KVM modules\n' "${MODULE_ROOT}" >&2
        exit 1
fi

if [ "${KERNEL_REL}" != "6.19.0-rc6-cofunc-tdx+" ]; then
        printf 'unexpected running kernel: %s\n' "${KERNEL_REL}" >&2
        printf 'expected: 6.19.0-rc6-cofunc-tdx+\n' >&2
        exit 1
fi

need_file "${SRC_IRQBYPASS}"
need_file "${SRC_KVM}"
need_file "${SRC_KVM_INTEL}"
need_file "${DST_IRQBYPASS}"
need_file "${DST_KVM}"
need_file "${DST_KVM_INTEL}"

if fuser /dev/kvm >/dev/null 2>&1; then
        printf '/dev/kvm is busy; stop QEMU/shadow-container users first\n' >&2
        fuser -v /dev/kvm >&2 || true
        exit 1
fi

backup_dir=${BACKUP_ROOT}/${KERNEL_REL}-$(date -u +%Y%m%d_%H%M%S)
mkdir -p "${backup_dir}/kernel/virt/lib" "${backup_dir}/kernel/arch/x86/kvm"
cp -a "${DST_IRQBYPASS}" "${backup_dir}/kernel/virt/lib/"
cp -a "${DST_KVM}" "${backup_dir}/kernel/arch/x86/kvm/"
cp -a "${DST_KVM_INTEL}" "${backup_dir}/kernel/arch/x86/kvm/"

install -D -m 0644 "${SRC_IRQBYPASS}" "${DST_IRQBYPASS}"
install -D -m 0644 "${SRC_KVM}" "${DST_KVM}"
install -D -m 0644 "${SRC_KVM_INTEL}" "${DST_KVM_INTEL}"
depmod "${KERNEL_REL}"
sync -f "${DST_KVM}" 2>/dev/null || sync

modprobe -r kvm_intel
modprobe -r kvm
modprobe -r irqbypass
modprobe irqbypass
modprobe kvm
modprobe kvm_intel tdx=1

printf 'backup_dir=%s\n' "${backup_dir}"
printf 'loaded_irqbypass_srcversion=%s\n' "$(cat /sys/module/irqbypass/srcversion)"
printf 'loaded_kvm_srcversion=%s\n' "$(cat /sys/module/kvm/srcversion)"
printf 'loaded_kvm_intel_srcversion=%s\n' "$(cat /sys/module/kvm_intel/srcversion)"
printf 'kvm_intel_tdx=%s\n' "$(cat /sys/module/kvm_intel/parameters/tdx)"
