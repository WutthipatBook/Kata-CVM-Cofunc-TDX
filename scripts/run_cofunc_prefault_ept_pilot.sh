#!/usr/bin/env bash
# Trace one pre-fault CoFunc handler. Video and DNA remain separate boundaries.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
TRACE_WRAPPER=${TRACE_WRAPPER:-$BUNDLE/scripts/run_ept_trace_around.sh}
ANALYZER=${ANALYZER:-$BUNDLE/scripts/analyze_cofunc_ept_trace.py}
GATE=${GATE:-$BUNDLE/scripts/kata_tdx_host_safety_gate.sh}
RUNNER=${RUNNER:-$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh}
TRACE_PATCH=${TRACE_PATCH:-$BUNDLE/patches/cofunc-artifact-oldabi/0015-Signal-CoFunc-handler-EPT-trace-window.patch}
WORKLOAD=${1:-}
STAMP=$(date -u +%Y%m%d_%H%M%S)
RUN_ROOT=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_ept_${WORKLOAD//\//_}_$STAMP}
COFUNC_OUT=${COFUNC_OUT:-$ROOT/results/cofunc_prefault_ept_${WORKLOAD//\//_}_$STAMP}
RUNTIME_BACKUP=$RUN_ROOT/runtime-backup

stop_re='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
log_loss_re='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages|[Ll]ost [0-9]+ kernel messages|messages dropped'
level2_re='CoFunc old-ABI TDX SEPT change:.*level=[2-9]|changed-live-split.*level=[2-9]|CoFunc TDX SEPT private lifecycle:.*level=[2-9]|CoFunc (old-ABI )?private TDP.*(level|iter_level|goal|req)=2|CoFunc TDX private TDP.*(level|iter_level)=2'
promotion_re='CoFunc old-ABI private 2M promotion|CoFunc.*private.*2M.*promot|CoFunc.*2M.*promot.*private'

run_rc=125
postflight_gate_rc=125
evidence_rc=0
prefault_target_passed=unknown
active_phase=initializing
finished=0

usage() {
	cat <<'EOF'
Usage: run_cofunc_prefault_ept_pilot.sh WORKLOAD

Supported workloads:
  fn_py_video_processing
  fn_py_dna_visualisation

Builds diagnostic images, then launches exactly one traced pre-fault CoFunc
VM with no retry. It never advances to the other workload.
EOF
}

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

capture_host_state() {
	local label=$1
	{
		printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
		printf 'kernel=%s\n' "$(uname -r)"
		printf 'loadavg='; cat /proc/loadavg
		printf 'kvm_srcversion=%s\n' "$(< /sys/module/kvm/srcversion)"
		printf 'kvm_intel_srcversion=%s\n' "$(< /sys/module/kvm_intel/srcversion)"
		printf 'kvm_intel_tdx=%s\n' "$(< /sys/module/kvm_intel/parameters/tdx)"
		printf 'tdp_mmu=%s\n' "$(< /sys/module/kvm/parameters/tdp_mmu)"
	} >"$RUN_ROOT/host-state-$label.txt"
	ps -eo pid,ppid,psr,pcpu,pmem,stat,comm,args --sort=-pcpu \
		>"$RUN_ROOT/processes-$label.txt"
}

check_helpers() {
	curl --connect-timeout 5 --max-time 15 -fsS -X POST \
		http://127.0.0.1:8888/get_param \
		--data-urlencode "fn_name=testcases/$WORKLOAD" >/dev/null
	curl --connect-timeout 5 --max-time 15 -fsS \
		http://127.0.0.1:9000/minio/health/ready >/dev/null
}

verify_source_restoration() {
	[[ -s $RUNTIME_BACKUP/sha256.before ]] || \
		fail "missing runtime source baseline hash"
	[[ -s $RUNTIME_BACKUP/sha256.restored ]] || \
		fail "missing runtime source restoration hash"
	cmp -s "$RUNTIME_BACKUP/sha256.before" "$RUNTIME_BACKUP/sha256.restored" || \
		fail "runtime source restoration hash mismatch"
	if rg -q 'fault_trace_signal|COFUNC_EPT_TRACE_URL' \
		"$ROOT/cofunc-artifact-oldabi/testcases/tools/template.py" \
		"$ROOT/cofunc-artifact-oldabi/testcases/tools/tasks/run_sc_fork/action.sh" \
		"$ROOT/cofunc-artifact-oldabi/testcases/tools/lean_container/start.sh"; then
		fail "handler trace instrumentation remained after restoration"
	fi
}

finish() {
	local entry_rc=$? final_rc
	(( finished == 0 )) || return
	finished=1
	trap - EXIT
	set +e
	if [[ -r $RUN_ROOT/dmesg-before.log ]]; then
		capture_dmesg after
		{ diff -u "$RUN_ROOT/dmesg-before.log" "$RUN_ROOT/dmesg-after.log" 2>/dev/null || true; } |
			sed -n '/^+[^+]/p' >"$RUN_ROOT/dmesg-after.delta"
	else
		: >"$RUN_ROOT/dmesg-after.delta"
		evidence_rc=1
	fi
	capture_host_state after
	sudo -n "$GATE" post-cofunc-prefault-ept-pilot \
		>"$RUN_ROOT/postflight.log" 2>&1
	postflight_gate_rc=$?
	if rg -n -i "$stop_re|$log_loss_re|$level2_re|$promotion_re" \
		"$RUN_ROOT/dmesg-after.delta" >"$RUN_ROOT/prohibited-kernel-markers.txt"; then
		evidence_rc=1
	fi
	{
		printf 'run_rc=%d\n' "$run_rc"
		printf 'postflight_gate_rc=%d\n' "$postflight_gate_rc"
		printf 'evidence_rc=%d\n' "$evidence_rc"
		printf 'entry_rc=%d\n' "$entry_rc"
		printf 'active_phase=%s\n' "$active_phase"
		printf 'prefault_target_passed=%s\n' "$prefault_target_passed"
		printf 'run_root=%s\n' "$RUN_ROOT"
		printf 'cofunc_out=%s\n' "$COFUNC_OUT"
	} >"$RUN_ROOT/harness-result.txt"
	printf 'run_root=%s\ncofunc_out=%s\n' "$RUN_ROOT" "$COFUNC_OUT"
	printf 'run_rc=%d postflight_gate_rc=%d evidence_rc=%d prefault_target_passed=%s\n' \
		"$run_rc" "$postflight_gate_rc" "$evidence_rc" "$prefault_target_passed"
	final_rc=$entry_rc
	(( run_rc == 0 )) || final_rc=$run_rc
	(( postflight_gate_rc == 0 )) || final_rc=$postflight_gate_rc
	(( evidence_rc == 0 )) || final_rc=$evidence_rc
	exit "$final_rc"
}

[[ $# == 1 ]] || {
	usage >&2
	exit 2
}
case "$WORKLOAD" in
fn_py_video_processing|fn_py_dna_visualisation) ;;
*)
	usage >&2
	exit 2
	;;
esac
for command in cmp curl diff jq ps rg sed sha256sum sudo; do
	need "$command"
done
for executable in "$TRACE_WRAPPER" "$ANALYZER" "$GATE" "$RUNNER"; do
	[[ -x $executable ]] || fail "missing executable: $executable"
done
[[ -r $TRACE_PATCH ]] || fail "missing trace patch: $TRACE_PATCH"
sudo -n true 2>/dev/null || fail "sudo credentials are not cached; run sudo -v"
[[ ! -e $RUN_ROOT ]] || fail "refusing to reuse run root: $RUN_ROOT"
[[ ! -e $COFUNC_OUT ]] || fail "refusing to reuse CoFunc output: $COFUNC_OUT"
mkdir -p "$RUN_ROOT"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'workload=%s\n' "$WORKLOAD"
	printf 'samples=1\n'
	printf 'warmups=0\n'
	printf 'automatic_retries=0\n'
	printf 'cofunc_out=%s\n' "$COFUNC_OUT"
} >"$RUN_ROOT/experiment-env.txt"
cp "$0" "$RUN_ROOT/harness.sh"
sha256sum "$0" "$TRACE_WRAPPER" "$ANALYZER" "$RUNNER" \
	"$BUNDLE/scripts/kata_tdx_ept_fault_trace.bt" \
	"$BUNDLE/scripts/ept_trace_signal_server.py" "$TRACE_PATCH" \
	>"$RUN_ROOT/experiment-inputs.sha256"

sudo -n "$GATE" pre-cofunc-prefault-ept-pilot | tee "$RUN_ROOT/preflight.log"
check_helpers
capture_host_state before
capture_dmesg before

active_phase=traced-cofunc
set +e
CNI_GATEWAY=127.0.0.1 "$TRACE_WRAPPER" "$RUN_ROOT/ept-trace" -- \
	bash -c '
		set -Eeuo pipefail
		: "${EPT_TRACE_BASE_URL:?missing EPT_TRACE_BASE_URL}"
		exec sudo -n env \
			ROOT="$1" BUNDLE="$2" OUT="$3" \
			COFUNC_OLDABI_RUNTIME_BACKUP_DIR="$4" \
			COFUNC_OLDABI_RUNTIME_TRACE_PATCH="$5" \
			COFUNC_EPT_TRACE_URL="${EPT_TRACE_BASE_URL}/1" \
			STOP_AFTER_SMOKE=0 \
			COFUNC_OLDABI_SKIP_FACE_SMOKE=1 \
			COFUNC_OLDABI_RUNTIME_WORKLOADS="$6" \
			COFUNC_OLDABI_RUNTIME_REPETITIONS=1 \
			COFUNC_WORKLOAD_TIMEOUT_SEC=600 \
			COFUNC_KVM_BUSY_RETRIES=1 \
			COFUNC_TDX_SMP=16 \
			"$7"
	' bash "$ROOT" "$BUNDLE" "$COFUNC_OUT" "$RUNTIME_BACKUP" \
		"$TRACE_PATCH" "$WORKLOAD" "$RUNNER" \
	2>&1 | tee "$RUN_ROOT/traced-runner.log"
trace_command_rc=${PIPESTATUS[0]}
set -e
(( trace_command_rc == 0 )) || fail "traced CoFunc command failed: $trace_command_rc"

active_phase=verification
verify_source_restoration
analyzer_log="$COFUNC_OUT/log/$WORKLOAD/sc_fork.log"
run_log="$COFUNC_OUT/run-${WORKLOAD//\//_}-1.log"
[[ -s $analyzer_log ]] || fail "missing CoFunc analyzer log: $analyzer_log"
[[ -s $run_log ]] || fail "missing CoFunc run log: $run_log"
[[ $(jq -s 'length' "$analyzer_log") == 1 ]] || fail "expected one CoFunc analyzer row"

active_phase=analysis
"$ANALYZER" \
	--workload "$WORKLOAD" \
	--analyzer-log "$analyzer_log" \
	--run-log "$run_log" \
	--trace "$RUN_ROOT/ept-trace/ept-events.tsv" \
	--signals "$RUN_ROOT/ept-trace/signals.tsv" \
	--trace-result "$RUN_ROOT/ept-trace/trace-result.txt" \
	--output-dir "$RUN_ROOT/analysis" | tee "$RUN_ROOT/analysis-result.txt"
prefault_target_passed=$(jq -r '.prefault_target_passed' \
	"$RUN_ROOT/analysis/cofunc_ept_trace.json")
[[ $prefault_target_passed == true || $prefault_target_passed == false ]] || \
	fail "invalid pre-fault target result: $prefault_target_passed"

active_phase=complete
run_rc=0
exit 0
