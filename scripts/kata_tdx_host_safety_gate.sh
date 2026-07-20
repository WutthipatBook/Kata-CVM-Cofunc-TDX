#!/usr/bin/env bash
# Read-only gate for starting or tearing down Kata-TDX VMs on the old-ABI host.
set -uo pipefail

EXPECTED_KERNEL=${EXPECTED_KERNEL:-5.19.0-cofunc-tdx-5.19+}
MODE=full
if [[ ${1:-} == --kernel-only ]]; then
    MODE=kernel-only
    shift
fi
CONTEXT=${1:-manual}

KERNEL_STOP_RE='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
status=0

ok() {
    printf 'OK   %-30s %s\n' "$1" "$2"
}

fail() {
    printf 'FAIL %-30s %s\n' "$1" "$2"
    status=1
}

printf 'Kata-TDX host safety gate\n'
printf 'context=%s\n' "$CONTEXT"
printf 'mode=%s\n' "$MODE"

kernel_log=""
if kernel_log=$(dmesg --time-format iso 2>/dev/null); then
    kernel_stop_markers=$(printf '%s\n' "$kernel_log" | rg -m 5 "$KERNEL_STOP_RE" || true)
    if [[ -n $kernel_stop_markers ]]; then
        fail "current-boot kernel log" "$(printf '%s' "$kernel_stop_markers" | tr '\n' '; ')"
    else
        ok "current-boot kernel log" "no known KVM/TDX stop markers"
    fi
else
    fail "current-boot kernel log" "unreadable; run this gate with sudo"
fi

if [[ $MODE == full ]]; then
    if [[ $(uname -r) == "$EXPECTED_KERNEL" ]]; then
        ok "kernel" "$EXPECTED_KERNEL"
    else
        fail "kernel" "got $(uname -r), expected $EXPECTED_KERNEL"
    fi

    if [[ -e /dev/kvm ]]; then
        ok "/dev/kvm" "present"
    else
        fail "/dev/kvm" "missing"
    fi

    tdx_param=$(cat /sys/module/kvm_intel/parameters/tdx 2>/dev/null || true)
    if [[ $tdx_param == Y ]]; then
        ok "kvm_intel.tdx" "$tdx_param"
    else
        fail "kvm_intel.tdx" "${tdx_param:-missing}"
    fi

    kvm_intel_users=$(awk '$1 == "kvm_intel" { print $3 }' /proc/modules 2>/dev/null)
    if [[ $kvm_intel_users == 0 ]]; then
        ok "kvm_intel use count" "0"
    else
        fail "kvm_intel use count" "${kvm_intel_users:-module missing}"
    fi

    if command -v lsof >/dev/null 2>&1; then
        kvm_owners=$(lsof -nP /dev/kvm 2>/dev/null || true)
        if [[ -n $kvm_owners ]]; then
            fail "/dev/kvm owners" "$(printf '%s' "$kvm_owners" | tr '\n' '; ')"
        else
            ok "/dev/kvm owners" "none"
        fi
    else
        fail "lsof" "missing"
    fi

    active_processes=$(ps -eo pid=,comm=,args= | awk '
        $2 == "awk" { next }
        $2 ~ /^qemu-system/ || $0 ~ /containerd-shim-kata/ || $0 ~ /qemu_tdx_oldabi_wrapper[.]sh/ { print }
    ')
    if [[ -n $active_processes ]]; then
        fail "Kata/QEMU processes" "$(printf '%s' "$active_processes" | head -n 5 | tr '\n' '; ')"
    else
        ok "Kata/QEMU processes" "none"
    fi

    if command -v ctr >/dev/null 2>&1; then
        kata_records=""
        for namespace in default k8s.io; do
            if container_list=$(ctr -n "$namespace" containers ls 2>&1); then
                namespace_records=$(printf '%s\n' "$container_list" | awk -v ns="$namespace" '
                    NR > 1 && ($1 ~ /^kata-tdx-/ || $NF ~ /kata/) { print ns ": " $0 }
                ')
                if [[ -n $namespace_records ]]; then
                    kata_records+="${namespace_records}"$'\n'
                fi
            else
                fail "containerd namespace" "$namespace: $container_list"
            fi
        done
        if [[ -n $kata_records ]]; then
            fail "Kata container records" "$(printf '%s' "$kata_records" | head -n 5 | tr '\n' '; ')"
        else
            ok "Kata container records" "none in default or k8s.io"
        fi
    else
        fail "ctr" "missing"
    fi
fi

if (( status == 0 )); then
    printf 'host_safety=ready\n'
else
    printf 'host_safety=not-ready\n'
fi
exit "$status"
