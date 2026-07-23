#!/usr/bin/env bash
# Reproduce the on-demand Thumbnailer startup failure with one bounded VM.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
ARTIFACT=$ROOT/cofunc-artifact-oldabi
TRACE_WRAPPER=$BUNDLE/scripts/run_ept_trace_around.sh
TRACE_PROGRAM=$BUNDLE/scripts/cofunc_ept_fault_count.bt
BPFTRACE=${BPFTRACE:-/usr/local/bin/bpftrace}
RUNNER=$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
GATE=$BUNDLE/scripts/kata_tdx_host_safety_gate.sh
OLD_PREFLIGHT=$BUNDLE/scripts/oldabi_tdx_host_preflight.sh
TRACE_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0017-Signal-CoFunc-handler-EPT-matrix-windows.patch
ON_DEMAND_CVM_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0018-Diagnostic-disable-prefault-and-expose-stats.patch
WORKLOAD=fn_js_thumbnailer
STAMP=$(date -u +%Y%m%d_%H%M%S)
RUN_ROOT=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_on_demand_thumbnail_probe_$STAMP}
COFUNC_OUT=${COFUNC_OUT:-$ROOT/results/cofunc_on_demand_thumbnail_probe_$STAMP}
PROBE_TIMEOUT_SEC=${PROBE_TIMEOUT_SEC:-180}

CONFIG=$ARTIFACT/cvm_os/.config
SPLIT_C=$ARTIFACT/cvm_os/kernel/split-container/split_container.c
IRQ_C=$ARTIFACT/cvm_os/kernel/arch/x86_64/irq/irq_entry.c
CAP_GROUP_H=$ARTIFACT/cvm_os/kernel/include/object/cap_group.h
SNAPSHOT_C=$ARTIFACT/cvm_os/kernel/split-container/snapshot.c
ISO=$ARTIFACT/cvm_os/build/chcore.iso
KERNEL_ISO=$ARTIFACT/cvm_os/build/kernel/arch/x86_64/boot/intel_tdx/chcore.iso

stop_re='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
log_loss_re='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages|[Ll]ost [0-9]+ kernel messages|messages dropped'
level2_re='CoFunc old-ABI TDX SEPT change:.*level=[2-9]|changed-live-split.*level=[2-9]|CoFunc TDX SEPT private lifecycle:.*level=[2-9]|CoFunc (old-ABI )?private TDP.*(level|iter_level|goal|req)=2|CoFunc TDX private TDP.*(level|iter_level)=2'
promotion_re='CoFunc old-ABI private 2M promotion|CoFunc.*private.*2M.*promot|CoFunc.*2M.*promot.*private'
clock_assert_re="Environment::GetNow.*Assertion.*now.*timer_base"

run_rc=125
workload_rc=125
postflight_gate_rc=125
evidence_rc=0
probe_result=not-run
active_phase=initializing
finished=0

fail() {
	run_rc=1
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

capture_dmesg() {
	local label=$1
	sudo -n dmesg --time-format iso >"$RUN_ROOT/dmesg-$label.log"
}

hash_source_state() {
	sha256sum "$CONFIG" "$SPLIT_C" "$IRQ_C" "$CAP_GROUP_H" \
		"$SNAPSHOT_C" "$ISO" "$KERNEL_ISO"
}

result_value() {
	local key=$1 file=$2
	awk -F= -v key="$key" '$1 == key { print $2 }' "$file"
}

verify_restoration() {
	local mode_root=$RUN_ROOT/on-demand
	cmp -s "$mode_root/runtime-backup/sha256.before" \
		"$mode_root/runtime-backup/sha256.restored" \
		|| fail "runtime source restoration mismatch"
	cmp -s "$mode_root/cvm-backup/sha256.before" \
		"$mode_root/cvm-backup/sha256.restored" \
		|| fail "CVM source or boot restoration mismatch"
	[[ $(< "$mode_root/cvm-backup/build-clean.rc") == 0 ]] \
		|| fail "CVM build cleanup failed"
	if [[ -f $mode_root/cvm-backup/configure-restore.rc ]]; then
		[[ $(< "$mode_root/cvm-backup/configure-restore.rc") == 0 ]] \
			|| fail "CVM CMake restoration failed"
	fi
	[[ $(< "$mode_root/cvm-backup/compiled-prefault-mode") == OFF ]] \
		|| fail "diagnostic image was not compiled in true on-demand mode"
	for image in \
		"$mode_root/cvm-backup/kernel.img.diagnostic" \
		"$mode_root/cvm-backup/chcore.iso.diagnostic"; do
		[[ -f $image ]] || fail "missing compiled diagnostic image: $image"
		if LC_ALL=C grep -aFq "CoFunc private pre-fault:" "$image"; then
			fail "diagnostic image still contains private pre-fault code: $image"
		fi
	done
}

finish() {
	local entry_rc=$? final_rc match_re
	(( finished == 0 )) || return
	finished=1
	trap - EXIT
	set +e
	if [[ -r $RUN_ROOT/dmesg-before.log ]]; then
		capture_dmesg after
		{ diff -u "$RUN_ROOT/dmesg-before.log" "$RUN_ROOT/dmesg-after.log" 2>/dev/null || true; } \
			| sed -n '/^+[^+]/p' >"$RUN_ROOT/dmesg-after.delta"
		match_re="$stop_re|$log_loss_re|$level2_re|$promotion_re"
		if rg -n -i "$match_re" "$RUN_ROOT/dmesg-after.delta" \
			>"$RUN_ROOT/prohibited-kernel-markers.txt"; then
			evidence_rc=1
		else
			: >"$RUN_ROOT/prohibited-kernel-markers.txt"
		fi
	else
		evidence_rc=1
	fi
	sudo -n "$GATE" post-cofunc-on-demand-thumbnail-probe \
		>"$RUN_ROOT/postflight.log" 2>&1
	postflight_gate_rc=$?
	hash_source_state >"$RUN_ROOT/source-state-after.sha256" 2>/dev/null \
		|| evidence_rc=1
	if [[ -s $RUN_ROOT/source-state-before.sha256 && -s $RUN_ROOT/source-state-after.sha256 ]]; then
		cmp -s "$RUN_ROOT/source-state-before.sha256" \
			"$RUN_ROOT/source-state-after.sha256" || evidence_rc=1
	else
		evidence_rc=1
	fi
	{
		printf 'run_rc=%d\n' "$run_rc"
		printf 'workload_rc=%d\n' "$workload_rc"
		printf 'postflight_gate_rc=%d\n' "$postflight_gate_rc"
		printf 'evidence_rc=%d\n' "$evidence_rc"
		printf 'entry_rc=%d\n' "$entry_rc"
		printf 'probe_result=%s\n' "$probe_result"
		printf 'active_phase=%s\n' "$active_phase"
		printf 'run_root=%s\n' "$RUN_ROOT"
		printf 'cofunc_out=%s\n' "$COFUNC_OUT"
	} >"$RUN_ROOT/harness-result.txt"
	printf 'run_root=%s\ncofunc_out=%s\n' "$RUN_ROOT" "$COFUNC_OUT"
	printf 'probe_result=%s workload_rc=%d run_rc=%d postflight_gate_rc=%d evidence_rc=%d\n' \
		"$probe_result" "$workload_rc" "$run_rc" "$postflight_gate_rc" "$evidence_rc"
	final_rc=$entry_rc
	(( run_rc == 0 )) || final_rc=$run_rc
	(( postflight_gate_rc == 0 )) || final_rc=$postflight_gate_rc
	(( evidence_rc == 0 )) || final_rc=$evidence_rc
	exit "$final_rc"
}

for command in awk bash cmp diff dmesg grep jq patch ps rg sed sha256sum sudo tee; do
	need "$command"
done
for executable in "$TRACE_WRAPPER" "$RUNNER" "$GATE" "$OLD_PREFLIGHT" "$BPFTRACE"; do
	[[ -x $executable ]] || fail "missing executable: $executable"
done
for input in "$TRACE_PROGRAM" "$TRACE_PATCH" "$ON_DEMAND_CVM_PATCH"; do
	[[ -r $input ]] || fail "missing input: $input"
done
[[ $PROBE_TIMEOUT_SEC =~ ^[1-9][0-9]*$ ]] \
	|| fail "PROBE_TIMEOUT_SEC must be a positive integer"
sudo -n true 2>/dev/null || fail "sudo credentials are not cached; run sudo -v"
[[ ! -e $RUN_ROOT ]] || fail "refusing to reuse run root: $RUN_ROOT"
[[ ! -e $COFUNC_OUT ]] || fail "refusing to reuse CoFunc output: $COFUNC_OUT"
mkdir -p "$RUN_ROOT/on-demand"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'workload=%s\n' "$WORKLOAD"
	printf 'mode=on-demand\n'
	printf 'samples=1\n'
	printf 'automatic_retries=0\n'
	printf 'timeout_seconds=%s\n' "$PROBE_TIMEOUT_SEC"
	printf 'purpose=reproduce pre-window Node monotonic-clock failure\n'
} >"$RUN_ROOT/experiment-env.txt"
cp "$0" "$RUN_ROOT/harness.sh"
sha256sum "$0" "$TRACE_WRAPPER" "$TRACE_PROGRAM" "$RUNNER" \
	"$TRACE_PATCH" "$ON_DEMAND_CVM_PATCH" \
	>"$RUN_ROOT/experiment-inputs.sha256"

active_phase=preflight
sudo -n "$GATE" pre-cofunc-on-demand-thumbnail-probe | tee "$RUN_ROOT/preflight.log"
sudo -n "$OLD_PREFLIGHT" | tee "$RUN_ROOT/oldabi-preflight.log"
rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' "$CONFIG" \
	|| fail "private pre-fault config is not enabled at baseline"
patch --dry-run -d "$ARTIFACT" -p1 -i "$ON_DEMAND_CVM_PATCH" >/dev/null \
	|| fail "on-demand CVM instrumentation patch does not apply"
if ps -eo comm=,args= | awk '$1 == "bpftrace" { found=1 } END { exit !found }'; then
	fail "bpftrace is already active"
fi
sudo -n "$BPFTRACE" --dry-run "$TRACE_PROGRAM" 1 \
	>"$RUN_ROOT/bpftrace-dry-run.log" 2>&1 \
	|| fail "count-only EPT bpftrace program failed its dry-run"
hash_source_state >"$RUN_ROOT/source-state-before.sha256"
capture_dmesg before

active_phase=traced-thumbnail
set +e
TRACE_PROGRAM="$TRACE_PROGRAM" CNI_GATEWAY=127.0.0.1 \
	"$TRACE_WRAPPER" "$RUN_ROOT/on-demand/ept-trace" -- \
	bash -c '
		set -Eeuo pipefail
		: "${EPT_TRACE_BASE_URL:?missing EPT_TRACE_BASE_URL}"
		exec sudo -n env \
			ROOT="$1" BUNDLE="$2" OUT="$3" \
			COFUNC_OLDABI_RUNTIME_BACKUP_DIR="$4" \
			COFUNC_OLDABI_CVM_BACKUP_DIR="$5" \
			COFUNC_OLDABI_CVM_INSTRUMENTATION_PATCH="$6" \
			COFUNC_OLDABI_RUNTIME_TRACE_PATCH="$7" \
			COFUNC_OLDABI_RUNTIME_TRACE_MATRIX=1 \
			COFUNC_OLDABI_REUSE_LOCAL_FINAL_IMAGE=1 \
			COFUNC_OLDABI_HUGEPAGE_PREFLIGHT_WORKLOAD=fn_py_dna_visualisation \
			COFUNC_OLDABI_HUGEPAGE_PREFLIGHT_OUT="$8" \
			COFUNC_EPT_TRACE_URL="${EPT_TRACE_BASE_URL}" \
			STOP_AFTER_SMOKE=0 \
			COFUNC_OLDABI_SKIP_FACE_SMOKE=1 \
			COFUNC_OLDABI_RUNTIME_WORKLOADS=fn_js_thumbnailer \
			COFUNC_OLDABI_RUNTIME_REPETITIONS=1 \
			COFUNC_OLDABI_REGULAR_MEMFILE=0 \
			COFUNC_WORKLOAD_TIMEOUT_SEC="$9" \
			COFUNC_KVM_BUSY_RETRIES=1 \
			COFUNC_TDX_SMP=16 \
			COFUNC_HOST_SAFETY_GATE="${10}" \
			COFUNC_KERNEL_GUARD=1 \
			"${11}"
	' bash "$ROOT" "$BUNDLE" "$COFUNC_OUT" \
		"$RUN_ROOT/on-demand/runtime-backup" \
		"$RUN_ROOT/on-demand/cvm-backup" \
		"$ON_DEMAND_CVM_PATCH" "$TRACE_PATCH" \
		"$RUN_ROOT/on-demand/hugepage-preflight" "$PROBE_TIMEOUT_SEC" \
		"$GATE" "$RUNNER" \
	2>&1 | tee "$RUN_ROOT/on-demand/traced-runner.log"
workload_rc=${PIPESTATUS[0]}
set -e

active_phase=classification
verify_restoration
run_log=$COFUNC_OUT/run-fn_js_thumbnailer-1.log
trace_result=$RUN_ROOT/on-demand/ept-trace/trace-result.txt
signals=$RUN_ROOT/on-demand/ept-trace/signals.tsv
[[ -s $run_log ]] || fail "missing Thumbnailer run log: $run_log"
[[ $(result_value trace_ready "$trace_result") == 1 ]] \
	|| fail "trace did not become ready"
[[ $(result_value trace_stopped "$trace_result") == 1 ]] \
	|| fail "trace did not stop cleanly"
[[ $(result_value loss_markers "$trace_result") == 0 ]] \
	|| fail "trace reported loss"
if rg -q "$clock_assert_re" "$run_log"; then
	[[ $(result_value signal_begin_count "$trace_result") == 0 ]] \
		|| fail "clock assertion occurred after a handler begin signal"
	[[ $(result_value signal_end_count "$trace_result") == 0 ]] \
		|| fail "clock assertion unexpectedly produced a handler end signal"
	probe_result=clock-assertion-reproduced
elif (( workload_rc == 0 )); then
	[[ $(result_value signal_begin_count "$trace_result") == 1 ]] \
		|| fail "successful workload lacks one begin signal"
	[[ $(result_value signal_end_count "$trace_result") == 1 ]] \
		|| fail "successful workload lacks one end signal"
	awk -F'\t' 'NR == 2 && $3 == 7 && $4 == "begin" { begin=1 }
		NR == 3 && $3 == 7 && $4 == "end" { end=1 }
		END { exit !(begin && end && NR == 3) }' "$signals" \
		|| fail "successful workload has an unexpected signal sequence"
	[[ $(jq -s 'length' "$COFUNC_OUT/log/$WORKLOAD/sc_fork.log") == 1 ]] \
		|| fail "successful workload lacks one analyzer record"
	if rg -q 'CoFunc private pre-fault:' "$run_log"; then
		fail "successful workload unexpectedly ran private pre-fault"
	fi
	probe_result=workload-passed
else
	fail "Thumbnailer failed without the expected Node clock assertion: $workload_rc"
fi

active_phase=complete
run_rc=0
exit 0
