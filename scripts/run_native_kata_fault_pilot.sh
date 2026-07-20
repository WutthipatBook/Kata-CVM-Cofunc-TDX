#!/usr/bin/env bash
# Run one bounded Native/Kata fault comparison. DNA and video are deliberately
# separate approval boundaries; this script never advances to another workload.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ARTIFACT_DIR=${ARTIFACT_DIR:-/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact}
GENERIC_KATA_RUNNER=${GENERIC_KATA_RUNNER:-$BUNDLE/scripts/run_kata_tdx_cri_workload.sh}
TRACE_WRAPPER=${TRACE_WRAPPER:-$BUNDLE/scripts/run_ept_trace_around.sh}
ANALYZER=${ANALYZER:-$BUNDLE/scripts/analyze_fault_comparison.py}
GATE=${GATE:-$BUNDLE/scripts/kata_tdx_host_safety_gate.sh}
RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}
SAMPLES=${SAMPLES:-3}
WORKLOAD=${1:-}
RUN_TOKEN=${RUN_TOKEN:-flt-$(date -u +%H%M%S)-$((BASHPID % 100))}
RUN_ROOT=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/native_kata_fault_${WORKLOAD//\//_}_$(date -u +%Y%m%d_%H%M%S)}

stop_re='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
log_loss_re='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages|[Ll]ost [0-9]+ kernel messages|messages dropped'
level2_re='CoFunc old-ABI TDX SEPT change:.*level=[2-9]|changed-live-split.*level=[2-9]|CoFunc TDX SEPT private lifecycle:.*level=[2-9]|CoFunc (old-ABI )?private TDP.*(level|iter_level|goal|req)=2|CoFunc TDX private TDP.*(level|iter_level)=2'
promotion_re='CoFunc old-ABI private 2M promotion|CoFunc.*private.*2M.*promot|CoFunc.*2M.*promot.*private'

run_rc=125
final_gate_rc=125
evidence_rc=0
finished=0
active_phase=initializing

usage() {
	cat <<'EOF'
Usage: run_native_kata_fault_pilot.sh WORKLOAD

Supported workloads:
  fn_py_dna_visualisation
  fn_py_video_processing

SAMPLES defaults to 3. The script performs one excluded Native warm-up, the
measured Native forks, one excluded Kata cold warm-up, then measured cold Kata
VMs under EPT tracing. It never retries and never starts the other workload.
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
		printf 'online_cpus='; cat /sys/devices/system/cpu/online
		printf 'kvm_srcversion=%s\n' "$(< /sys/module/kvm/srcversion)"
		printf 'kvm_intel_srcversion=%s\n' "$(< /sys/module/kvm_intel/srcversion)"
		printf 'kvm_intel_tdx=%s\n' "$(< /sys/module/kvm_intel/parameters/tdx)"
		printf 'tdp_mmu=%s\n' "$(< /sys/module/kvm/parameters/tdp_mmu)"
		for file in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
			[[ -r $file ]] && printf '%s=%s\n' "$file" "$(<"$file")"
		done
		[[ ! -r /sys/devices/system/cpu/intel_pstate/no_turbo ]] || \
			printf 'intel_pstate_no_turbo=%s\n' "$(< /sys/devices/system/cpu/intel_pstate/no_turbo)"
	} >"$RUN_ROOT/host-state-$label.txt"
	lscpu >"$RUN_ROOT/lscpu-$label.txt"
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

build_source_image() {
	active_phase=build-source-image
	(
		cd "$ARTIFACT_DIR/testcases/testcases/$WORKLOAD"
		"$ARTIFACT_DIR/testcases/tools/build.sh"
	)
	docker image inspect "${WORKLOAD##*/}:latest" \
		>"$RUN_ROOT/source-image-inspect.json"
}

run_native_phase() {
	local label=$1 samples=$2 log_root=$3
	active_phase=$label
	mkdir -p "$log_root"
	LOG_DIR="$log_root" \
		"$ARTIFACT_DIR/testcases/tools/tasks/run_lean_fork/action.sh" \
		"$WORKLOAD" "$samples"
}

run_kata_phase() {
	local label=$1 samples=$2 log_root=$3 child_dir=$4
	active_phase=$label
	RUN_DIR="$child_dir" \
	LOG_ROOT="$log_root" \
	RUN_TOKEN="${RUN_TOKEN}-${label}" \
	PREPARE_ONLY=0 \
	SKIP_PREPARE=1 \
	START_ITERATION=1 \
	KATA_VCPU_CPU=0 \
	RUNTIME_ENDPOINT="$RUNTIME_ENDPOINT" \
		"$GENERIC_KATA_RUNNER" "$WORKLOAD" "$samples"
}

verify_instrumented_log() {
	local path=$1 expected=$2
	[[ -r $path ]] || fail "missing analyzer log: $path"
	[[ $(jq -s 'length' "$path") == "$expected" ]] || \
		fail "sample count mismatch in $path"
	jq -e -s '
		all(.[];
			([.t_exec, .t_cpu_exec, .t_network,
			  .n_minflt_exec, .n_majflt_exec,
			  .n_nvcsw_exec, .n_nivcsw_exec] | all(type == "number")))
	' "$path" >/dev/null || fail "missing process-fault metrics in $path"
}

verify_trace_result() {
	local result=$1 expected=$2 expected_maps
	expected_maps=$((expected * 4))
	[[ -r $result ]] || fail "missing trace result: $result"
	rg -q '^command_rc=0$' "$result" || fail "traced Kata command failed"
	rg -q '^trace_ready=1$' "$result" || fail "EPT trace did not become ready exactly once"
	rg -q '^trace_stopped=1$' "$result" || fail "EPT trace did not stop cleanly"
	rg -q '^loss_markers=0$' "$result" || fail "EPT trace reported lost events"
	rg -q "^signal_begin_count=${expected}$" "$result" || \
		fail "EPT trace begin-signal count mismatch"
	rg -q "^signal_end_count=${expected}$" "$result" || \
		fail "EPT trace end-signal count mismatch"
	rg -q "^vm_aggregate_records=${expected_maps}$" "$result" || \
		fail "EPT trace aggregate-map count mismatch"
}

verify_vcpu_affinity() {
	local root=$1 expected=$2 files
	mapfile -t files < <(find "$root" -type f -name vcpu-affinity.txt -print | sort)
	[[ ${#files[@]} == "$expected" ]] || \
		fail "vCPU affinity evidence count mismatch under $root: ${#files[@]} != $expected"
	for file in "${files[@]}"; do
		rg -q '^target_cpu=0$' "$file" || fail "wrong vCPU target in $file"
		rg -q '^vcpu_tid=[0-9]+ ' "$file" || fail "missing vCPU TID in $file"
		rg -q 'current affinity list: 0$' "$file" || \
			fail "unverified CPU 0 affinity in $file"
	done
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
	sudo -n "$GATE" post-native-kata-fault-pilot \
		>"$RUN_ROOT/postflight.log" 2>&1
	final_gate_rc=$?
	if rg -n -i "$stop_re|$log_loss_re|$level2_re|$promotion_re" \
		"$RUN_ROOT/dmesg-after.delta" >"$RUN_ROOT/prohibited-kernel-markers.txt"; then
		evidence_rc=1
	fi
	{
		printf 'run_rc=%d\n' "$run_rc"
		printf 'postflight_gate_rc=%d\n' "$final_gate_rc"
		printf 'evidence_rc=%d\n' "$evidence_rc"
		printf 'entry_rc=%d\n' "$entry_rc"
		printf 'active_phase=%s\n' "$active_phase"
		printf 'run_root=%s\n' "$RUN_ROOT"
	} >"$RUN_ROOT/harness-result.txt"
	printf 'run_root=%s\n' "$RUN_ROOT"
	printf 'run_rc=%d postflight_gate_rc=%d evidence_rc=%d\n' \
		"$run_rc" "$final_gate_rc" "$evidence_rc"
	final_rc=$entry_rc
	(( run_rc == 0 )) || final_rc=$run_rc
	(( final_gate_rc == 0 )) || final_rc=$final_gate_rc
	(( evidence_rc == 0 )) || final_rc=$evidence_rc
	exit "$final_rc"
}

[[ $# == 1 ]] || {
	usage >&2
	exit 2
}
case "$WORKLOAD" in
fn_py_dna_visualisation|fn_py_video_processing) ;;
*)
	usage >&2
	exit 2
	;;
esac
[[ $SAMPLES =~ ^[1-5]$ ]] || fail "SAMPLES must be between 1 and 5"
(( ${#RUN_TOKEN} <= 13 )) || fail "RUN_TOKEN must be at most 13 characters: $RUN_TOKEN"

for command in curl diff docker find jq lscpu ps rg sed sha256sum sort sudo; do
	need "$command"
done
for executable in "$GENERIC_KATA_RUNNER" "$TRACE_WRAPPER" "$ANALYZER" "$GATE"; do
	[[ -x $executable ]] || fail "missing executable: $executable"
done
[[ -x $ARTIFACT_DIR/testcases/tools/tasks/run_lean_fork/action.sh ]] || \
	fail "missing Native runner"
rg -q '^print\(f"n_minflt_exec ' "$ARTIFACT_DIR/testcases/tools/template.py" || \
	fail "fault instrumentation is not applied; run manage_fault_instrumentation.sh apply"
rg -q '^def add_exec_resource_metrics\(\):' "$ARTIFACT_DIR/testcases/tools/analyze.py" || \
	fail "instrumented analyzer is not applied"
sudo -n true 2>/dev/null || fail "sudo credentials are not cached; run sudo -v"
[[ ! -e $RUN_ROOT ]] || fail "refusing to reuse run root: $RUN_ROOT"
mkdir -p "$RUN_ROOT"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'workload=%s\n' "$WORKLOAD"
	printf 'samples=%d\n' "$SAMPLES"
	printf 'native_warmups=1\n'
	printf 'kata_warmups=1\n'
	printf 'run_token=%s\n' "$RUN_TOKEN"
	printf 'native_second_level_faults=N/A\n'
	printf 'native_cpuset_cpu=0\n'
	printf 'kata_vcpu_cpu=0\n'
} >"$RUN_ROOT/experiment-env.txt"
cp "$0" "$RUN_ROOT/harness.sh"
sha256sum "$0" "$GENERIC_KATA_RUNNER" "$TRACE_WRAPPER" "$ANALYZER" \
	"$BUNDLE/scripts/kata_tdx_ept_fault_trace.bt" \
	"$BUNDLE/scripts/ept_trace_signal_server.py" \
	"$BUNDLE/scripts/manage_fault_instrumentation.sh" \
	"$BUNDLE/patches/measurement/0001-Measure-exec-faults-cpu-and-network.patch" \
	>"$RUN_ROOT/experiment-inputs.sha256"

sudo -n "$GATE" pre-native-kata-fault-pilot | tee "$RUN_ROOT/preflight.log"
check_helpers
capture_host_state before
capture_dmesg before

# Rebuild once so Native and Kata derive from the same instrumented source image.
build_source_image

run_native_phase native-warmup 1 "$RUN_ROOT/native-warmup-log"
run_native_phase native-measured "$SAMPLES" "$RUN_ROOT/native-measured-log"
native_log="$RUN_ROOT/native-measured-log/$WORKLOAD/lean_fork.log"
verify_instrumented_log "$native_log" "$SAMPLES"

sudo -n "$GATE" between-native-and-kata | tee "$RUN_ROOT/between-native-and-kata.log"

# Build/import only; this creates no Kata VM.
active_phase=kata-prebuild
RUN_DIR="$RUN_ROOT/kata-prebuild" \
LOG_ROOT="$RUN_ROOT/kata-prebuild-log" \
RUN_TOKEN="${RUN_TOKEN}-prep" \
PREPARE_ONLY=1 \
SKIP_PREPARE=0 \
KATA_VCPU_CPU=0 \
RUNTIME_ENDPOINT="$RUNTIME_ENDPOINT" \
	"$GENERIC_KATA_RUNNER" "$WORKLOAD" 1

run_kata_phase kata-warmup 1 "$RUN_ROOT/kata-warmup-log" "$RUN_ROOT/kata-warmup"
verify_vcpu_affinity "$RUN_ROOT/kata-warmup-log" 1
sudo -n "$GATE" before-traced-kata | tee "$RUN_ROOT/before-traced-kata.log"

active_phase=kata-measured-traced
"$TRACE_WRAPPER" "$RUN_ROOT/ept-trace" -- env \
	RUN_DIR="$RUN_ROOT/kata-measured" \
	LOG_ROOT="$RUN_ROOT/kata-measured-log" \
	RUN_TOKEN="${RUN_TOKEN}-km" \
	PREPARE_ONLY=0 \
	SKIP_PREPARE=1 \
	START_ITERATION=1 \
	KATA_VCPU_CPU=0 \
	RUNTIME_ENDPOINT="$RUNTIME_ENDPOINT" \
	"$GENERIC_KATA_RUNNER" "$WORKLOAD" "$SAMPLES"

kata_log="$RUN_ROOT/kata-measured-log/$WORKLOAD/kata_launch.log"
verify_trace_result "$RUN_ROOT/ept-trace/trace-result.txt" "$SAMPLES"
verify_vcpu_affinity "$RUN_ROOT/kata-measured-log" "$SAMPLES"
verify_instrumented_log "$kata_log" "$SAMPLES"

active_phase=analysis
"$ANALYZER" \
	--workload "$WORKLOAD" \
	--native-log "$native_log" \
	--kata-log "$kata_log" \
	--trace "$RUN_ROOT/ept-trace/ept-events.tsv" \
	--output-dir "$RUN_ROOT/analysis"

active_phase=complete
run_rc=0
exit 0
