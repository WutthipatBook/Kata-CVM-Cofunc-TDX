#!/usr/bin/env bash
# Count handler-window EPT faults once per Fig. 11 function in paired modes.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
ARTIFACT=$ROOT/cofunc-artifact-oldabi
TRACE_WRAPPER=$BUNDLE/scripts/run_ept_trace_around.sh
TRACE_PROGRAM=$BUNDLE/scripts/cofunc_ept_fault_count.bt
BPFTRACE=${BPFTRACE:-/usr/local/bin/bpftrace}
ANALYZER=$BUNDLE/scripts/analyze_cofunc_prefault_fault_savings.py
RUNNER=$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
GATE=$BUNDLE/scripts/kata_tdx_host_safety_gate.sh
OLD_PREFLIGHT=$BUNDLE/scripts/oldabi_tdx_host_preflight.sh
TRACE_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0017-Signal-CoFunc-handler-EPT-matrix-windows.patch
PREFAULT_CVM_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0006-Diagnostic-expose-guest-accept-pgfault-stats.patch
ON_DEMAND_CVM_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0018-Diagnostic-disable-prefault-and-expose-stats.patch
STAMP=$(date -u +%Y%m%d_%H%M%S)
RUN_ROOT=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_fault_savings_$STAMP}

CONFIG=$ARTIFACT/cvm_os/.config
SPLIT_C=$ARTIFACT/cvm_os/kernel/split-container/split_container.c
IRQ_C=$ARTIFACT/cvm_os/kernel/arch/x86_64/irq/irq_entry.c
CAP_GROUP_H=$ARTIFACT/cvm_os/kernel/include/object/cap_group.h
SNAPSHOT_C=$ARTIFACT/cvm_os/kernel/split-container/snapshot.c
ISO=$ARTIFACT/cvm_os/build/chcore.iso
KERNEL_ISO=$ARTIFACT/cvm_os/build/kernel/arch/x86_64/boot/intel_tdx/chcore.iso

WORKLOADS=(
	fn_py_compression
	fn_py_face_detection
	fn_py_image_processing
	fn_py_sentiment
	fn_py_video_processing
	fn_py_dna_visualisation
	fn_js_thumbnailer
	fn_js_uploader
	chain_js_alexa/fn_js_alexa_frontend
	chain_js_alexa/fn_js_alexa_interact
	chain_js_alexa/fn_js_alexa_smarthome
	chain_js_alexa/fn_js_alexa_tv
)

stop_re='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
log_loss_re='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages|[Ll]ost [0-9]+ kernel messages|messages dropped'
level2_re='CoFunc old-ABI TDX SEPT change:.*level=[2-9]|changed-live-split.*level=[2-9]|CoFunc TDX SEPT private lifecycle:.*level=[2-9]|CoFunc (old-ABI )?private TDP.*(level|iter_level|goal|req)=2|CoFunc TDX private TDP.*(level|iter_level)=2'
promotion_re='CoFunc old-ABI private 2M promotion|CoFunc.*private.*2M.*promot|CoFunc.*2M.*promot.*private'

run_rc=125
postflight_gate_rc=125
evidence_rc=0
active_phase=initializing
finished=0
completed_modes=()

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

check_mode_restoration() {
	local mode=$1 mode_root=$RUN_ROOT/$mode
	cmp -s "$mode_root/runtime-backup/sha256.before" \
		"$mode_root/runtime-backup/sha256.restored" \
		|| fail "$mode runtime source restoration mismatch"
	cmp -s "$mode_root/cvm-backup/sha256.before" \
		"$mode_root/cvm-backup/sha256.restored" \
		|| fail "$mode CVM source or boot restoration mismatch"
	[[ $(< "$mode_root/cvm-backup/build-clean.rc") == 0 ]] \
		|| fail "$mode CVM build cleanup failed"
}

verify_mode() {
	local mode=$1 mode_root=$RUN_ROOT/$mode out=$mode_root/cofunc-out
	local workload safe gate_count delta_count expected_prefault actual_prefault
	[[ -L $out ]] || fail "missing $mode CoFunc output link"
	[[ $(awk -F= '$1 == "command_rc" { print $2 }' "$mode_root/ept-trace/trace-result.txt") == 0 ]] \
		|| fail "$mode traced command failed"
	[[ $(awk -F= '$1 == "signal_begin_count" { print $2 }' "$mode_root/ept-trace/trace-result.txt") == 12 ]] \
		|| fail "$mode trace does not contain 12 begin signals"
	[[ $(awk -F= '$1 == "signal_end_count" { print $2 }' "$mode_root/ept-trace/trace-result.txt") == 12 ]] \
		|| fail "$mode trace does not contain 12 end signals"
	[[ $(awk -F= '$1 == "loss_markers" { print $2 }' "$mode_root/ept-trace/trace-result.txt") == 0 ]] \
		|| fail "$mode trace reported loss"

	for workload in "${WORKLOADS[@]}"; do
		safe=${workload//\//_}
		[[ $(jq -s 'length' "$out/log/$workload/sc_fork.log") == 1 ]] \
			|| fail "$mode $workload does not have one analyzer row"
		jq -e -s 'length == 1 and (.[0].n_pgfault_exec | type == "number") and
			(.[0].t_pgfault_exec | type == "number") and
			(.[0].t_exec | type == "number")' \
			"$out/log/$workload/sc_fork.log" >/dev/null \
			|| fail "$mode $workload lacks fault telemetry"
		if [[ $mode == prefault ]]; then
			expected_prefault=1
		else
			expected_prefault=0
		fi
		actual_prefault=$(awk '/CoFunc private pre-fault:/{count++} END{print count+0}' \
			"$out/run-$safe-1.log")
		if [[ $expected_prefault == 1 && $actual_prefault -eq 0 ]]; then
			fail "$mode $workload lacks the pre-fault marker"
		fi
		if [[ $expected_prefault == 0 && $actual_prefault -ne 0 ]]; then
			fail "$mode $workload unexpectedly ran private pre-fault"
		fi
	done

	gate_count=$(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' \
		| awk 'END { print NR }')
	delta_count=$(find "$out/safety" -maxdepth 1 -type f -name 'dmesg-measured-*.delta' \
		| awk 'END { print NR }')
	[[ $gate_count == 24 ]] || fail "$mode expected 24 host gates, found $gate_count"
	[[ $delta_count == 12 ]] || fail "$mode expected 12 kernel deltas, found $delta_count"
	if [[ -n $(find "$out/safety" -maxdepth 1 -type f -name '*-prohibited.txt' \
		-size +0c -print -quit) ]]; then
		fail "$mode has prohibited per-workload kernel evidence"
	fi
	while IFS= read -r gate_log; do
		rg -q '^host_safety=ready$' "$gate_log" \
			|| fail "$mode host gate did not report ready: $gate_log"
	done < <(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' | sort)
	check_mode_restoration "$mode"
}

run_mode() {
	local mode=$1 cvm_patch=$2
	local mode_root=$RUN_ROOT/$mode out=$ROOT/results/cofunc_${mode}_fault_count_$STAMP
	[[ ! -e $mode_root ]] || fail "refusing to reuse mode root: $mode_root"
	[[ ! -e $out ]] || fail "refusing to reuse CoFunc output: $out"
	mkdir -p "$mode_root"
	printf '%s\n' "$out" >"$mode_root/cofunc-out.path"

	active_phase=$mode-trace
	set +e
	TRACE_PROGRAM="$TRACE_PROGRAM" CNI_GATEWAY=127.0.0.1 \
		"$TRACE_WRAPPER" "$mode_root/ept-trace" -- \
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
				COFUNC_EPT_TRACE_URL="${EPT_TRACE_BASE_URL}" \
				STOP_AFTER_SMOKE=0 \
				COFUNC_OLDABI_SKIP_FACE_SMOKE=1 \
				COFUNC_OLDABI_RUNTIME_WORKLOADS="$8" \
				COFUNC_OLDABI_RUNTIME_REPETITIONS=1 \
				COFUNC_OLDABI_REGULAR_MEMFILE=0 \
				COFUNC_WORKLOAD_TIMEOUT_SEC=1200 \
				COFUNC_KVM_BUSY_RETRIES=1 \
				COFUNC_TDX_SMP=16 \
				COFUNC_HOST_SAFETY_GATE="$9" \
				COFUNC_KERNEL_GUARD=1 \
				"${10}"
		' bash "$ROOT" "$BUNDLE" "$out" \
			"$mode_root/runtime-backup" "$mode_root/cvm-backup" \
			"$cvm_patch" "$TRACE_PATCH" "${WORKLOADS[*]}" "$GATE" "$RUNNER" \
		2>&1 | tee "$mode_root/traced-runner.log"
	trace_rc=${PIPESTATUS[0]}
	set -e
	(( trace_rc == 0 )) || fail "$mode traced matrix failed: $trace_rc"
	ln -s "$out" "$mode_root/cofunc-out"
	verify_mode "$mode"
	completed_modes+=("$mode")
	rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' "$CONFIG" \
		|| fail "$mode did not restore the pre-fault config"
}

prepare_images() {
	local prep_root=$RUN_ROOT/image-preflight
	local prep_rc
	mkdir -p "$prep_root"
	active_phase=image-preflight
	set +e
	sudo -n env \
		ROOT="$ROOT" BUNDLE="$BUNDLE" \
		OUT="$ROOT/results/cofunc_fault_savings_image_preflight_$STAMP" \
		COFUNC_OLDABI_RUNTIME_BACKUP_DIR="$prep_root/runtime-backup" \
		COFUNC_OLDABI_RUNTIME_TRACE_PATCH="$TRACE_PATCH" \
		COFUNC_OLDABI_RUNTIME_TRACE_MATRIX=1 \
		COFUNC_OLDABI_REUSE_LOCAL_FINAL_IMAGE=1 \
		COFUNC_OLDABI_PREPARE_IMAGES_ONLY=1 \
		STOP_AFTER_SMOKE=0 \
		COFUNC_OLDABI_SKIP_FACE_SMOKE=1 \
		COFUNC_OLDABI_RUNTIME_WORKLOADS="${WORKLOADS[*]}" \
		COFUNC_OLDABI_RUNTIME_REPETITIONS=1 \
		"$RUNNER" 2>&1 | tee "$prep_root/prepare.log"
	prep_rc=${PIPESTATUS[0]}
	set -e
	(( prep_rc == 0 )) || fail "network-free image preflight failed: $prep_rc"
	cmp -s "$prep_root/runtime-backup/sha256.before" \
		"$prep_root/runtime-backup/sha256.restored" \
		|| fail "image preflight did not restore runtime source"
	hash_source_state >"$prep_root/source-state-after.sha256"
	cmp -s "$RUN_ROOT/source-state-before.sha256" \
		"$prep_root/source-state-after.sha256" \
		|| fail "image preflight changed the source or boot baseline"
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
	sudo -n "$GATE" post-cofunc-prefault-fault-savings \
		>"$RUN_ROOT/postflight.log" 2>&1
	postflight_gate_rc=$?
	hash_source_state >"$RUN_ROOT/source-state-after.sha256" 2>/dev/null \
		|| evidence_rc=1
	if [[ -s $RUN_ROOT/source-state-before.sha256 && -s $RUN_ROOT/source-state-after.sha256 ]]; then
		cmp -s "$RUN_ROOT/source-state-before.sha256" "$RUN_ROOT/source-state-after.sha256" \
			|| evidence_rc=1
	else
		evidence_rc=1
	fi
	{
		printf 'run_rc=%d\n' "$run_rc"
		printf 'postflight_gate_rc=%d\n' "$postflight_gate_rc"
		printf 'evidence_rc=%d\n' "$evidence_rc"
		printf 'entry_rc=%d\n' "$entry_rc"
		printf 'active_phase=%s\n' "$active_phase"
		printf 'completed_modes=%s\n' "${completed_modes[*]}"
		printf 'run_root=%s\n' "$RUN_ROOT"
	} >"$RUN_ROOT/harness-result.txt"
	printf 'run_root=%s\n' "$RUN_ROOT"
	printf 'run_rc=%d postflight_gate_rc=%d evidence_rc=%d completed_modes=%s\n' \
		"$run_rc" "$postflight_gate_rc" "$evidence_rc" "${completed_modes[*]}"
	final_rc=$entry_rc
	(( run_rc == 0 )) || final_rc=$run_rc
	(( postflight_gate_rc == 0 )) || final_rc=$postflight_gate_rc
	(( evidence_rc == 0 )) || final_rc=$evidence_rc
	exit "$final_rc"
}

for command in awk bash cmp diff dmesg docker find findmnt jq patch ps python3 rg \
	sed sha256sum sort sudo tee xargs; do
	need "$command"
done
for executable in "$TRACE_WRAPPER" "$ANALYZER" "$RUNNER" "$GATE" "$OLD_PREFLIGHT" "$BPFTRACE"; do
	[[ -x $executable ]] || fail "missing executable: $executable"
done
for input in "$TRACE_PROGRAM" "$TRACE_PATCH" "$PREFAULT_CVM_PATCH" "$ON_DEMAND_CVM_PATCH"; do
	[[ -r $input ]] || fail "missing input: $input"
done
sudo -n true 2>/dev/null || fail "sudo credentials are not cached; run sudo -v"
[[ ! -e $RUN_ROOT ]] || fail "refusing to reuse run root: $RUN_ROOT"
mkdir -p "$RUN_ROOT"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'metric=handler-window host EPT page-fault tracepoint events\n'
	printf 'samples_per_function_per_mode=1\n'
	printf 'automatic_retries=0\n'
	printf 'workloads=%s\n' "${WORKLOADS[*]}"
} >"$RUN_ROOT/experiment-env.txt"
cp "$0" "$RUN_ROOT/harness.sh"
sha256sum "$0" "$TRACE_WRAPPER" "$TRACE_PROGRAM" "$ANALYZER" "$RUNNER" \
	"$TRACE_PATCH" "$PREFAULT_CVM_PATCH" "$ON_DEMAND_CVM_PATCH" \
	>"$RUN_ROOT/experiment-inputs.sha256"

active_phase=preflight
sudo -n "$GATE" pre-cofunc-prefault-fault-savings | tee "$RUN_ROOT/preflight.log"
sudo -n "$OLD_PREFLIGHT" | tee "$RUN_ROOT/oldabi-preflight.log"
rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' "$CONFIG" \
	|| fail "private pre-fault config is not enabled at baseline"
rg -q 'unsigned long sc_n_pgfault' "$CAP_GROUP_H" \
	|| fail "first-level page-fault counter source is missing"
patch --dry-run -d "$ARTIFACT" -p1 -i "$PREFAULT_CVM_PATCH" >/dev/null \
	|| fail "pre-fault CVM instrumentation patch does not apply"
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
prepare_images
capture_dmesg before

run_mode on-demand "$ON_DEMAND_CVM_PATCH"
run_mode prefault "$PREFAULT_CVM_PATCH"

active_phase=analysis
"$ANALYZER" \
	--on-demand-root "$RUN_ROOT/on-demand" \
	--prefault-root "$RUN_ROOT/prefault" \
	--output-dir "$RUN_ROOT/analysis" | tee "$RUN_ROOT/analysis-result.txt"
find "$RUN_ROOT/analysis" -type f -print0 | sort -z | xargs -0 sha256sum \
	>"$RUN_ROOT/analysis.sha256"

active_phase=complete
run_rc=0
exit 0
