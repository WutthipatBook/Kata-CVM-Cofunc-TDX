#!/usr/bin/env bash
# Collect the paper-aligned CoFunc fork matrix with private pre-fault enabled.
# No warm-up, retry, bpftrace, or runtime telemetry is permitted. The runner
# stops after the first failed workload, unsafe host gate, or kernel marker.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
ARTIFACT=$ROOT/cofunc-artifact-oldabi
RUNNER=$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh
GATE=$BUNDLE/scripts/kata_tdx_host_safety_gate.sh
OLD_PREFLIGHT=$BUNDLE/scripts/oldabi_tdx_host_preflight.sh
STAGE_TOOL=$BUNDLE/scripts/cofunc_e2e_stage_breakdown.py
PLOT_TOOL=$BUNDLE/scripts/plot_cofunc_prefault_handler_comparison.py
PERF_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0016-Restore-original-page-fault-accounting-for-performance.patch
BASELINE=${BASELINE_STAGE_JSON:-/home/booklyn/BookArchive/Images/measured_tdx_fig11_paper_aligned_stages_20260717_060234/combined_stage_breakdown.json}
STAMP=$(date -u +%Y%m%d_%H%M%S)
RUN_ROOT=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_fig11_measurements_$STAMP}
COFUNC_OUT=${COFUNC_OUT:-$ROOT/results/cofunc_prefault_fig11_measurements_$STAMP}
RUNTIME_BACKUP=$RUN_ROOT/runtime-backup
CVM_BACKUP=$RUN_ROOT/cvm-backup
ANALYSIS_DIR=$RUN_ROOT/analysis

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
EXPECTED_COUNTS=(20 20 20 20 5 10 20 20 20 20 20 20)

stop_re='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
log_loss_re='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages|[Ll]ost [0-9]+ kernel messages|messages dropped'
level2_re='CoFunc old-ABI TDX SEPT change:.*level=[2-9]|changed-live-split.*level=[2-9]|CoFunc TDX SEPT private lifecycle:.*level=[2-9]|CoFunc (old-ABI )?private TDP.*(level|iter_level|goal|req)=2|CoFunc TDX private TDP.*(level|iter_level)=2'
promotion_re='CoFunc old-ABI private 2M promotion|CoFunc.*private.*2M.*promot|CoFunc.*2M.*promot.*private'

run_rc=125
postflight_gate_rc=125
evidence_rc=0
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
	dmesg --time-format iso >"$RUN_ROOT/dmesg-$label.log"
}

capture_host_state() {
	local label=$1
	{
		printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'kernel=%s\n' "$(uname -r)"
		printf 'loadavg='; cat /proc/loadavg
		printf 'kvm_srcversion=%s\n' "$(< /sys/module/kvm/srcversion)"
		printf 'kvm_intel_srcversion=%s\n' "$(< /sys/module/kvm_intel/srcversion)"
		printf 'kvm_intel_tdx=%s\n' "$(< /sys/module/kvm_intel/parameters/tdx)"
		printf 'thp_enabled=%s\n' "$(< /sys/kernel/mm/transparent_hugepage/enabled)"
		printf 'thp_defrag=%s\n' "$(< /sys/kernel/mm/transparent_hugepage/defrag)"
		df -h /Serverless /mnt/new_disk /home/booklyn
	} >"$RUN_ROOT/host-state-$label.txt"
	ps -eo pid,ppid,psr,pcpu,pmem,stat,comm,args --sort=-pcpu \
		>"$RUN_ROOT/processes-$label.txt"
}

hash_source_state() {
	sha256sum "$CONFIG" "$SPLIT_C" "$IRQ_C" "$CAP_GROUP_H" \
		"$SNAPSHOT_C" "$ISO" "$KERNEL_ISO"
}

make_delta() {
	{ diff -u "$RUN_ROOT/dmesg-before.log" "$RUN_ROOT/dmesg-after.log" 2>/dev/null || true; } \
		| sed -n '/^+[^+]/p' >"$RUN_ROOT/dmesg-after.delta"
}

check_overall_kernel_delta() {
	local match_re="$stop_re|$log_loss_re|$level2_re|$promotion_re"
	if rg -n -i "$match_re" "$RUN_ROOT/dmesg-after.delta" \
		>"$RUN_ROOT/prohibited-kernel-markers.txt"; then
		evidence_rc=1
	else
		: >"$RUN_ROOT/prohibited-kernel-markers.txt"
	fi
}

check_perf_prerequisites() {
	[[ -f $CONFIG && -f $SPLIT_C && -f $IRQ_C && -f $CAP_GROUP_H && -f $SNAPSHOT_C ]] \
		|| fail "missing CoFunc guest source"
	[[ -f $ISO && -f $KERNEL_ISO ]] || fail "missing CoFunc guest ISO"
	rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' "$CONFIG" \
		|| fail "private pre-fault is not enabled in $CONFIG"
	rg -q 'CoFunc private pre-fault:' "$SPLIT_C" \
		|| fail "private pre-fault source marker is missing"
	[[ $ISO -nt $SPLIT_C && $KERNEL_ISO -nt $SPLIT_C ]] \
		|| fail "guest ISO predates private pre-fault source"
	LC_ALL=C grep -aFq 'CoFunc private pre-fault:' "$ISO" \
		|| fail "guest ISO does not contain the private pre-fault marker"
	LC_ALL=C grep -aFq 'CoFunc private pre-fault:' "$KERNEL_ISO" \
		|| fail "kernel ISO does not contain the private pre-fault marker"
	if ps -eo comm=,args= | awk '$1 == "bpftrace" { found=1 } END { exit !found }'; then
		fail "bpftrace is active; refusing a performance collection"
	fi
	patch --dry-run -d "$ARTIFACT" -p1 -i "$PERF_PATCH" >/dev/null \
		|| fail "performance accounting patch does not apply cleanly"
}

verify_sample_matrix() {
	local index workload expected log_file run_log actual safe
	local expected_params=$RUN_ROOT/expected-run_sc_fork.params
	: >"$expected_params"
	for index in "${!WORKLOADS[@]}"; do
		printf '%s %s\n' "${WORKLOADS[$index]}" "${EXPECTED_COUNTS[$index]}" \
			>>"$expected_params"
	done
	cmp "$expected_params" "$COFUNC_OUT/run_sc_fork.params" \
		|| fail "run_sc_fork.params does not match the approved matrix"

	for index in "${!WORKLOADS[@]}"; do
		workload=${WORKLOADS[$index]}
		expected=${EXPECTED_COUNTS[$index]}
		log_file=$COFUNC_OUT/log/$workload/sc_fork.log
		safe=${workload//\//_}
		run_log=$COFUNC_OUT/run-$safe-$expected.log
		[[ -s $log_file ]] || fail "missing analyzer log: $log_file"
		[[ -s $run_log ]] || fail "missing workload log: $run_log"
		actual=$(jq -s 'length' "$log_file")
		[[ $actual == "$expected" ]] \
			|| fail "sample count mismatch for $workload: expected=$expected actual=$actual"
		jq -e -s --argjson expected "$expected" '
			length == $expected and all(.[];
				type == "object" and
				(.t_exec | type == "number" and . > 0) and
				(.t_e2e | type == "number" and . > 0) and
				(.t_boot_lean | type == "number") and
				(.t_boot_sc | type == "number") and
				(.t_boot_func | type == "number") and
				(has("n_pgfault_exec") | not))
		' "$log_file" >/dev/null \
			|| fail "invalid or diagnostic-contaminated analyzer rows: $workload"
		rg -q 'CoFunc private pre-fault:' "$run_log" \
			|| fail "missing private pre-fault runtime evidence: $workload"
	done

	local gate_count delta_count gate_log
	gate_count=$(find "$COFUNC_OUT/safety" -maxdepth 1 -type f -name 'host-*.log' \
		| awk 'END { print NR }')
	delta_count=$(find "$COFUNC_OUT/safety" -maxdepth 1 -type f -name 'dmesg-measured-*.delta' \
		| awk 'END { print NR }')
	[[ $gate_count == 24 ]] || fail "expected 24 per-workload host gates, found $gate_count"
	[[ $delta_count == 12 ]] || fail "expected 12 per-workload kernel deltas, found $delta_count"
	if [[ -n $(find "$COFUNC_OUT/safety" -maxdepth 1 -type f \
		-name '*-prohibited.txt' -size +0c -print -quit) ]]; then
		fail "per-workload prohibited kernel evidence is nonempty"
	fi
	while IFS= read -r gate_log; do
		rg -q '^host_safety=ready$' "$gate_log" \
			|| fail "a per-workload host gate did not report ready: $gate_log"
	done < <(find "$COFUNC_OUT/safety" -maxdepth 1 -type f -name 'host-*.log' | sort)
}

generate_analysis() {
	mkdir -p "$ANALYSIS_DIR/stages" "$ANALYSIS_DIR/handler-comparison"
	"$STAGE_TOOL" \
		--log-root "$COFUNC_OUT/log" \
		--workloads "${WORKLOADS[@]}" \
		--markdown "$ANALYSIS_DIR/stages/cofunc_prefault_stage_breakdown.md" \
		--csv "$ANALYSIS_DIR/stages/cofunc_prefault_stage_breakdown.csv" \
		--json "$ANALYSIS_DIR/stages/cofunc_prefault_stage_breakdown.json" \
		>"$ANALYSIS_DIR/stages/cofunc_prefault_stage_breakdown.stdout"
	"$PLOT_TOOL" \
		--baseline "$BASELINE" \
		--prefault "$ANALYSIS_DIR/stages/cofunc_prefault_stage_breakdown.json" \
		--out-dir "$ANALYSIS_DIR/handler-comparison" \
		| tee "$ANALYSIS_DIR/handler-comparison/plot-result.txt"
	find "$ANALYSIS_DIR" -type f -print0 | sort -z | xargs -0 sha256sum \
		>"$RUN_ROOT/analysis.sha256"
}

finish() {
	local entry_rc=$? final_rc
	(( finished == 0 )) || return
	finished=1
	trap - EXIT
	set +e
	if [[ -r $RUN_ROOT/dmesg-before.log ]]; then
		capture_dmesg after
		make_delta
		check_overall_kernel_delta
	else
		evidence_rc=1
		: >"$RUN_ROOT/dmesg-after.delta"
	fi
	capture_host_state after
	"$GATE" post-cofunc-prefault-fig11-measurements \
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
	if [[ -s $RUNTIME_BACKUP/sha256.before && -s $RUNTIME_BACKUP/sha256.restored ]]; then
		cmp -s "$RUNTIME_BACKUP/sha256.before" "$RUNTIME_BACKUP/sha256.restored" \
			|| evidence_rc=1
	else
		evidence_rc=1
	fi
	if [[ -s $CVM_BACKUP/sha256.before && -s $CVM_BACKUP/sha256.restored ]]; then
		cmp -s "$CVM_BACKUP/sha256.before" "$CVM_BACKUP/sha256.restored" \
			|| evidence_rc=1
	else
		evidence_rc=1
	fi
	[[ -s $CVM_BACKUP/build-clean.rc ]] \
		&& [[ $(< "$CVM_BACKUP/build-clean.rc") == 0 ]] \
		|| evidence_rc=1
	{
		printf 'run_rc=%d\n' "$run_rc"
		printf 'postflight_gate_rc=%d\n' "$postflight_gate_rc"
		printf 'evidence_rc=%d\n' "$evidence_rc"
		printf 'entry_rc=%d\n' "$entry_rc"
		printf 'active_phase=%s\n' "$active_phase"
		printf 'run_root=%s\n' "$RUN_ROOT"
		printf 'cofunc_out=%s\n' "$COFUNC_OUT"
	} >"$RUN_ROOT/harness-result.txt"
	printf 'run_root=%s\ncofunc_out=%s\n' "$RUN_ROOT" "$COFUNC_OUT"
	printf 'run_rc=%d postflight_gate_rc=%d evidence_rc=%d\n' \
		"$run_rc" "$postflight_gate_rc" "$evidence_rc"
	final_rc=$entry_rc
	(( run_rc == 0 )) || final_rc=$run_rc
	(( postflight_gate_rc == 0 )) || final_rc=$postflight_gate_rc
	(( evidence_rc == 0 )) || final_rc=$evidence_rc
	exit "$final_rc"
}

for command in awk cmake cmp diff dmesg docker find findmnt grep jq objdump patch ps \
	python3 rg sed sha256sum sort tee xargs; do
	need "$command"
done
[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run with sudo: sudo $0"
for executable in "$RUNNER" "$GATE" "$OLD_PREFLIGHT" "$STAGE_TOOL" "$PLOT_TOOL"; do
	[[ -x $executable ]] || fail "missing executable: $executable"
done
[[ -r $PERF_PATCH ]] || fail "missing performance patch: $PERF_PATCH"
[[ -r $BASELINE ]] || fail "missing baseline stage JSON: $BASELINE"
[[ ! -e $RUN_ROOT ]] || fail "refusing to reuse run root: $RUN_ROOT"
[[ ! -e $COFUNC_OUT ]] || fail "refusing to reuse CoFunc output: $COFUNC_OUT"
mkdir -p "$RUN_ROOT"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'sampling_rule=artifact-first-N\n'
	printf 'excluded_warmups=0\n'
	printf 'automatic_retries=0\n'
	printf 'private_prefault=enabled\n'
	printf 'bpftrace=disabled\n'
	printf 'runtime_telemetry=disabled\n'
	printf 'page_fault_accounting=artifact-original-non-atomic\n'
	printf 'baseline=%s\n' "$BASELINE"
	printf 'run_root=%s\n' "$RUN_ROOT"
	printf 'cofunc_out=%s\n' "$COFUNC_OUT"
} >"$RUN_ROOT/experiment-env.txt"
cp "$0" "$RUN_ROOT/harness.sh"
sha256sum "$0" "$RUNNER" "$GATE" "$OLD_PREFLIGHT" "$STAGE_TOOL" \
	"$PLOT_TOOL" "$PERF_PATCH" "$BASELINE" >"$RUN_ROOT/experiment-inputs.sha256"

active_phase=preflight
"$GATE" pre-cofunc-prefault-fig11-measurements | tee "$RUN_ROOT/preflight.log"
"$OLD_PREFLIGHT" | tee "$RUN_ROOT/oldabi-preflight.log"
check_perf_prerequisites
capture_host_state before
capture_dmesg before
hash_source_state >"$RUN_ROOT/source-state-before.sha256"

active_phase=measurement
set +e
env \
	-u COFUNC_OLDABI_RUNTIME_REPETITIONS \
	-u COFUNC_OLDABI_RUNTIME_EXTRA_PATCH \
	-u COFUNC_OLDABI_RUNTIME_FOLLOWUP_PATCH \
	-u COFUNC_OLDABI_RUNTIME_METRICS_PATCH \
	-u COFUNC_OLDABI_RUNTIME_TRACE_PATCH \
	ROOT="$ROOT" BUNDLE="$BUNDLE" OUT="$COFUNC_OUT" \
		COFUNC_OLDABI_RUNTIME_BACKUP_DIR="$RUNTIME_BACKUP" \
		COFUNC_OLDABI_CVM_BACKUP_DIR="$CVM_BACKUP" \
		COFUNC_OLDABI_CVM_EXTRA_PATCH="$PERF_PATCH" \
	COFUNC_OLDABI_RUNTIME_WORKLOADS="${WORKLOADS[*]}" \
	COFUNC_OLDABI_SKIP_FACE_SMOKE=1 \
	COFUNC_OLDABI_REGULAR_MEMFILE=0 \
	COFUNC_KVM_BUSY_RETRIES=1 \
	COFUNC_TDX_SMP=16 \
	COFUNC_HOST_SAFETY_GATE="$GATE" \
	COFUNC_KERNEL_GUARD=1 \
	COFUNC_WORKLOAD_TIMEOUT_SEC=1200 \
	STOP_AFTER_SMOKE=0 \
	"$RUNNER" 2>&1 | tee "$RUN_ROOT/runner.log"
runner_rc=${PIPESTATUS[0]}
set -e
(( runner_rc == 0 )) || {
	run_rc=$runner_rc
	exit "$runner_rc"
}

active_phase=verification
verify_sample_matrix
active_phase=analysis
generate_analysis
active_phase=complete
run_rc=0
exit 0
