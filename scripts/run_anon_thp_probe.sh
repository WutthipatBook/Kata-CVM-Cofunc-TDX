#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
SIZE_MB="${1:-${COFUNC_THP_PROBE_SIZE_MB:-512}}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT="${OUT:-$ROOT/results/anon_thp_probe_${SIZE_MB}mb_$STAMP}"
RUN_START_EPOCH=""
START_DELAY_SEC="${COFUNC_THP_PROBE_START_DELAY_SEC:-2}"

die() {
	echo "error: $*" >&2
	exit 1
}

record_kernel_journal() {
	[[ -n ${RUN_START_EPOCH:-} ]] || return 0
	if command -v journalctl >/dev/null 2>&1; then
		journalctl -k --since "@$RUN_START_EPOCH" --no-pager \
			>"$OUT/kernel-journal-since-start.log" 2>/dev/null || true
	fi
	dmesg -T >"$OUT/dmesg-final.log" 2>/dev/null || true
}

cleanup() {
	local rc=$?
	set +e
	if [[ -d ${OUT:-} ]]; then
		grep -E 'HugePages|Hugepagesize|AnonHugePages|ShmemHugePages|FileHugePages' \
			/proc/meminfo >"$OUT/meminfo-after.txt" 2>/dev/null || true
		record_kernel_journal
	fi
	exit "$rc"
}

main() {
	[[ $SIZE_MB =~ ^[0-9]+$ && $SIZE_MB -gt 0 ]] \
		|| die "size must be a positive integer MB, got $SIZE_MB"
	[[ $START_DELAY_SEC =~ ^[0-9]+$ ]] \
		|| die "COFUNC_THP_PROBE_START_DELAY_SEC must be a non-negative integer, got $START_DELAY_SEC"
	mkdir -p "$OUT"
	if [[ $START_DELAY_SEC -gt 0 ]]; then
		sleep "$START_DELAY_SEC"
	fi
	RUN_START_EPOCH="$(date -u +%s)"
	{
		echo "run_start_epoch=$RUN_START_EPOCH"
		echo "run_start_utc=$(date -u -d "@$RUN_START_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
		echo "size_mb=$SIZE_MB"
		echo "start_delay_sec=$START_DELAY_SEC"
		echo "thp_enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
		echo "thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true)"
	} >"$OUT/run-env.txt"
	grep -E 'HugePages|Hugepagesize|AnonHugePages|ShmemHugePages|FileHugePages' \
		/proc/meminfo >"$OUT/meminfo-before.txt" 2>/dev/null || true

	trap cleanup EXIT
	python3 - "$SIZE_MB" <<'PY' >"$OUT/anon-thp.log" 2>&1
import ctypes
import mmap
import sys
import time

size_mb = int(sys.argv[1])
size = size_mb * 1024 * 1024
page = 4096
libc = ctypes.CDLL(None, use_errno=True)
MADV_HUGEPAGE = 14

mm = mmap.mmap(-1, size, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS,
               prot=mmap.PROT_READ | mmap.PROT_WRITE)
addr = ctypes.addressof(ctypes.c_char.from_buffer(mm))
ret = libc.madvise(ctypes.c_void_p(addr), ctypes.c_size_t(size), MADV_HUGEPAGE)
print(f"size_mb={size_mb}")
print(f"mmap_addr=0x{addr:x}")
print(f"madvise_ret={ret}")
if ret != 0:
    print(f"madvise_errno={ctypes.get_errno()}")

for off in range(0, size, page):
    mm[off] = 1

print(f"touched_4k_pages={size // page}")
print("-- meminfo while mapped --")
with open("/proc/meminfo", "r", encoding="utf-8") as f:
    for line in f:
        if line.startswith(("AnonHugePages:", "ShmemHugePages:", "FileHugePages:",
                           "HugePages_Total:", "HugePages_Free:",
                           "HugePages_Rsvd:", "HugePages_Surp:",
                           "Hugepagesize:")):
            print(line.rstrip())
print("-- smaps_rollup while mapped --")
with open("/proc/self/smaps_rollup", "r", encoding="utf-8") as f:
    for line in f:
        if line.startswith(("Rss:", "Pss:", "Anonymous:", "AnonHugePages:")):
            print(line.rstrip())
time.sleep(2)
mm.close()
print("closed=1")
PY
}

main "$@"
