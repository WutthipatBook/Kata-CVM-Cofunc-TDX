#!/usr/bin/env bash
set -euo pipefail

EXPECTED_KERNEL="${EXPECTED_KERNEL:-5.19.0-cofunc-tdx-5.19+}"
ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
ARTIFACT="${ARTIFACT:-$ROOT/cofunc-artifact-oldabi}"
status=0

ok() {
	printf 'OK   %-30s %s\n' "$1" "$2"
}

warn() {
	printf 'WARN %-30s %s\n' "$1" "$2"
}

fail() {
	printf 'FAIL %-30s %s\n' "$1" "$2"
	status=1
}

meminfo_value() {
	awk -v key="$1:" '$1 == key { print $2 }' /proc/meminfo
}

active_thp_mode() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1" 2>/dev/null || true
}

printf 'Old-ABI TDX host preflight\n'
printf 'root=%s\n' "$ROOT"
printf 'artifact=%s\n\n' "$ARTIFACT"

kernel="$(uname -r)"
if [[ $kernel == "$EXPECTED_KERNEL" ]]; then
	ok "kernel" "$kernel"
else
	fail "kernel" "got $kernel expected $EXPECTED_KERNEL"
fi

if [[ -e /dev/kvm ]]; then
	ok "/dev/kvm" "present"
else
	fail "/dev/kvm" "missing"
fi

tdx_param="$(cat /sys/module/kvm_intel/parameters/tdx 2>/dev/null || true)"
if [[ $tdx_param == Y ]]; then
	ok "kvm_intel.tdx" "$tdx_param"
else
	fail "kvm_intel.tdx" "${tdx_param:-missing}"
fi

if findmnt "$ROOT" >/dev/null 2>&1 || findmnt /mnt/new_disk >/dev/null 2>&1; then
	mount_line="$(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /mnt/new_disk 2>/dev/null || true)"
	ok "/mnt/new_disk" "${mount_line:-mounted}"
else
	fail "/mnt/new_disk" "not mounted"
fi

if [[ -d $ARTIFACT ]]; then
	ok "artifact" "$ARTIFACT"
else
	fail "artifact" "missing: $ARTIFACT"
fi

thp_enabled="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
thp_mode="$(active_thp_mode /sys/kernel/mm/transparent_hugepage/enabled)"
if [[ $thp_mode == madvise ]]; then
	ok "THP enabled" "$thp_enabled"
else
	warn "THP enabled" "${thp_enabled:-missing}"
fi

thp_defrag="$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true)"
thp_defrag_mode="$(active_thp_mode /sys/kernel/mm/transparent_hugepage/defrag)"
if [[ $thp_defrag_mode == madvise ]]; then
	ok "THP defrag" "$thp_defrag"
else
	warn "THP defrag" "${thp_defrag:-missing}"
fi

huge_total="$(meminfo_value HugePages_Total)"
huge_free="$(meminfo_value HugePages_Free)"
huge_rsvd="$(meminfo_value HugePages_Rsvd)"
huge_surp="$(meminfo_value HugePages_Surp)"
nr_hugepages="$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || true)"
nr_overcommit="$(cat /proc/sys/vm/nr_overcommit_hugepages 2>/dev/null || true)"
huge_detail="total=$huge_total free=$huge_free rsvd=$huge_rsvd surp=$huge_surp nr=$nr_hugepages overcommit=$nr_overcommit"
if [[ ${huge_surp:-0} -gt 0 ]]; then
	fail "hugetlb pool" "$huge_detail"
elif [[ ${huge_total:-0} -gt 0 && ${huge_free:-0} -eq 0 && ${huge_rsvd:-0} -eq 0 ]]; then
	fail "hugetlb pool" "$huge_detail"
else
	ok "hugetlb pool" "$huge_detail"
fi

active="$(ps -eo pid=,comm=,args= | rg 'qemu-system|qemu-kvm|sc-runtime|run_sc_fork|start_lean_container|cvm\.sh' | rg -v 'oldabi_tdx_host_preflight| rg ' || true)"
if [[ -n $active ]]; then
	fail "active TDX processes" "$(printf '%s' "$active" | head -n 3 | tr '\n' '; ')"
else
	ok "active TDX processes" "none visible"
fi

STOP_MARKER_RE='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|Unknown SEAMCALL status code\(0xc0000b0d|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page'

kernel_log="$(journalctl -q -k -b --no-pager 2>/dev/null || true)"
kernel_log_source="journalctl"
if [[ -z $kernel_log ]]; then
	kernel_log="$(dmesg -T 2>/dev/null || true)"
	kernel_log_source="dmesg"
fi
if [[ -z $kernel_log ]]; then
	fail "current-boot kernel log" "unreadable; rerun preflight with sudo"
else
	kernel_stop_markers="$(printf '%s\n' "$kernel_log" | rg "$STOP_MARKER_RE" | head -n 3 || true)"
fi
if [[ -n ${kernel_stop_markers:-} ]]; then
	fail "current-boot kernel log" "$(printf '%s' "$kernel_stop_markers" | tr '\n' '; ')"
elif [[ -n ${kernel_log:-} ]]; then
	ok "current-boot kernel log" "no known stop markers found via $kernel_log_source"
fi

printf '\n'
if ((status == 0)); then
	printf 'preflight=ready\n'
else
	printf 'preflight=not-ready\n'
fi
exit "$status"
