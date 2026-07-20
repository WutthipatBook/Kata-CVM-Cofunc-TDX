#!/usr/bin/env bash
#
# Persist host-side CoFunc/KVM/QEMU diagnostics across a reboot.
# Usage:
#   scripts/cofunc_host_trace.sh --artifact /path/to/cofunc-artifact --slot 0 -- command ...
#   scripts/cofunc_host_trace.sh --slot 0

set -euo pipefail

RUN_ID=${RUN_ID:-cofunc_host_$(date -u +%Y%m%d_%H%M%S)}
TRACE_ROOT=${TRACE_ROOT:-/var/tmp/cofunc-trace}
ARTIFACT_DIR=${ARTIFACT_DIR:-}
SLOT_ID=${SLOT_ID:-0}

usage() {
        sed -n '2,8p' "$0" >&2
}

while [ "$#" -gt 0 ]; do
        case "$1" in
                --artifact)
                        ARTIFACT_DIR=$2
                        shift 2
                        ;;
                --slot)
                        SLOT_ID=$2
                        shift 2
                        ;;
                --run-id)
                        RUN_ID=$2
                        shift 2
                        ;;
                --trace-root)
                        TRACE_ROOT=$2
                        shift 2
                        ;;
                --help|-h)
                        usage
                        exit 0
                        ;;
                --)
                        shift
                        break
                        ;;
                *)
                        break
                        ;;
        esac
done

TRACE_DIR=${TRACE_ROOT}/${RUN_ID}
mkdir -p "${TRACE_DIR}"

log() {
        printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "${TRACE_DIR}/trace.log"
}

run_capture() {
        local name=$1
        shift
        {
                printf '$'
                printf ' %q' "$@"
                printf '\n'
                "$@"
        } >"${TRACE_DIR}/${name}.log" 2>&1 || true
}

copy_if_exists() {
        local path=$1
        local name=$2

        if [ -e "${path}" ]; then
                cp -a "${path}" "${TRACE_DIR}/${name}" 2>>"${TRACE_DIR}/trace.log" || true
        fi
}

start_kernel_followers() {
        if command -v stdbuf >/dev/null 2>&1; then
                stdbuf -oL -eL dmesg -W >"${TRACE_DIR}/dmesg-follow.log" 2>&1 &
        else
                dmesg -W >"${TRACE_DIR}/dmesg-follow.log" 2>&1 &
        fi
        echo $! >"${TRACE_DIR}/dmesg-follow.pid"

        if command -v journalctl >/dev/null 2>&1; then
                journalctl -kf --no-pager >"${TRACE_DIR}/journal-kernel-follow.log" 2>&1 &
                echo $! >"${TRACE_DIR}/journal-kernel-follow.pid"
        fi
}

stop_kernel_followers() {
        for pid_file in "${TRACE_DIR}"/*.pid; do
                [ -f "${pid_file}" ] || continue
                pid=$(cat "${pid_file}" 2>/dev/null || true)
                [ -n "${pid}" ] || continue
                kill "${pid}" 2>/dev/null || true
        done
        sync "${TRACE_DIR}" 2>/dev/null || sync
}

trap stop_kernel_followers EXIT

log "trace_dir=${TRACE_DIR}"
log "slot=${SLOT_ID}"
log "artifact=${ARTIFACT_DIR:-unset}"

run_capture host_uname uname -a
run_capture host_cmdline cat /proc/cmdline
run_capture host_boot_id cat /proc/sys/kernel/random/boot_id
run_capture host_mounts findmnt
run_capture host_lsblk lsblk -f
run_capture kvm_device ls -l /dev/kvm /sys/module/kvm /sys/module/kvm_intel
run_capture kvm_modinfo modinfo kvm
run_capture kvm_symbols bash -lc "grep -E ' split_container_| kvm_dev_ioctl_sc_get_vm| kvm_vm_ioctl_sc_alloc_vcpu' /proc/kallsyms | sort"
run_capture current_kernel_log dmesg

if [ -n "${ARTIFACT_DIR}" ]; then
        copy_if_exists "${ARTIFACT_DIR}/cvm_os/build/simulate.sh" artifact-simulate.sh
        copy_if_exists "${ARTIFACT_DIR}/testcases/tools/cvm.sh" artifact-cvm.sh
        copy_if_exists "${ARTIFACT_DIR}/cvm_os/exec_log_${SLOT_ID}" "artifact-exec_log_${SLOT_ID}.pre"
fi

{
        printf 'PATH=%s\n' "${PATH}"
        printf 'COFUNC_TDX_QEMU=%s\n' "${COFUNC_TDX_QEMU:-}"
        printf 'COFUNC_TDX_SMP=%s\n' "${COFUNC_TDX_SMP:-}"
        printf 'SLOT_ID=%s\n' "${SLOT_ID}"
} >"${TRACE_DIR}/env-selection.log"

find /mnt/nvme_500g /Serverless /home/"$(id -un)" /usr/local /opt \
        -type f -name qemu-system-x86_64 -perm -111 -print \
        >"${TRACE_DIR}/qemu-candidates.txt" 2>"${TRACE_DIR}/qemu-candidates.err" || true
if command -v qemu-system-x86_64 >/dev/null 2>&1; then
        command -v qemu-system-x86_64 >>"${TRACE_DIR}/qemu-candidates.txt"
fi
sort -u "${TRACE_DIR}/qemu-candidates.txt" -o "${TRACE_DIR}/qemu-candidates.txt"

while IFS= read -r qemu; do
        [ -n "${qemu}" ] || continue
        safe=$(printf '%s' "${qemu}" | tr '/ ' '__')
        {
                printf 'path=%s\n' "${qemu}"
                "${qemu}" --version 2>&1 | head -5 || true
                sha256sum "${qemu}" || true
                strings "${qemu}" | grep -E 'SLOT_ID|slot id|split_container|KVM_VM_TYPE_SC|system slot id' || true
        } >"${TRACE_DIR}/qemu-${safe}.log" 2>&1
done <"${TRACE_DIR}/qemu-candidates.txt"

start_kernel_followers

rc=0
if [ "$#" -gt 0 ]; then
        log "running wrapped command"
        set +e
        "$@" >"${TRACE_DIR}/command.log" 2>&1
        rc=$?
        set -e
        log "wrapped command rc=${rc}"
else
        log "no wrapped command; collected static host state only"
fi

if [ -n "${ARTIFACT_DIR}" ]; then
        copy_if_exists "${ARTIFACT_DIR}/cvm_os/exec_log_${SLOT_ID}" "artifact-exec_log_${SLOT_ID}.post"
fi
run_capture final_kernel_log dmesg
log "done"

exit "${rc}"
