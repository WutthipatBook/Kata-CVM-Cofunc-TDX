#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
ARTIFACT="$ROOT/cofunc-artifact-oldabi"
TOOLS="$ARTIFACT/testcases/tools"
HUGEPAGE_SH="$TOOLS/hugepage.sh"
WORKLOAD="${1:-${COFUNC_HUGEPAGE_PROBE_WORKLOAD:-fn_py_face_detection}}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
SAFE_WORKLOAD="${WORKLOAD//\//_}"
OUT="${OUT:-$ROOT/results/oldabi_hugepage_only_probe_${SAFE_WORKLOAD}_$STAMP}"
RUN_START_EPOCH=""

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
		(
			cd "$ARTIFACT/testcases/testcases/$WORKLOAD" || exit 0
			"$HUGEPAGE_SH" clean >/dev/null 2>&1 || true
		)
		cat /proc/sys/vm/nr_hugepages >"$OUT/nr_hugepages-after-clean" 2>/dev/null || true
		grep -E 'HugePages|Hugepagesize|AnonHugePages|ShmemHugePages|FileHugePages' \
			/proc/meminfo >"$OUT/meminfo-after-clean.txt" 2>/dev/null || true
		record_kernel_journal
	fi
	exit "$rc"
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0 [workload]"
	[[ -d "$ARTIFACT/testcases/testcases/$WORKLOAD" ]] \
		|| die "missing workload dir: $ARTIFACT/testcases/testcases/$WORKLOAD"
	[[ -x "$HUGEPAGE_SH" ]] || die "missing hugepage helper: $HUGEPAGE_SH"

	mkdir -p "$OUT"
	RUN_START_EPOCH="$(date -u +%s)"
	{
		echo "run_start_epoch=$RUN_START_EPOCH"
		echo "run_start_utc=$(date -u -d "@$RUN_START_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
		echo "workload=$WORKLOAD"
		echo "workload_dir=$ARTIFACT/testcases/testcases/$WORKLOAD"
		echo "memory_mb=$(cat "$ARTIFACT/testcases/testcases/$WORKLOAD/memory")"
		echo "hugepage_helper=$HUGEPAGE_SH"
	} >"$OUT/run-env.txt"
	cat /proc/sys/vm/nr_hugepages >"$OUT/nr_hugepages-before" 2>/dev/null || true
	grep -E 'HugePages|Hugepagesize|AnonHugePages|ShmemHugePages|FileHugePages' \
		/proc/meminfo >"$OUT/meminfo-before.txt" 2>/dev/null || true

	trap cleanup EXIT
	(
		cd "$ARTIFACT/testcases/testcases/$WORKLOAD"
		"$HUGEPAGE_SH"
	) >"$OUT/hugepage.log" 2>&1
	cat /proc/sys/vm/nr_hugepages >"$OUT/nr_hugepages-after-alloc" 2>/dev/null || true
	grep -E 'HugePages|Hugepagesize|AnonHugePages|ShmemHugePages|FileHugePages' \
		/proc/meminfo >"$OUT/meminfo-after-alloc.txt" 2>/dev/null || true
}

main "$@"
