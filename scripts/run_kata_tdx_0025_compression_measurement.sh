#!/usr/bin/env bash
# One-shot Fig. 11 compression measurement collection under the loaded
# patch-0023/0025 modules. It performs one untimed cold warm-up then exactly
# twenty measured cold launches. Each VM launch gets its own dmesg delta and
# reject check; the first unsafe result terminates the run without retry.
set -Eeuo pipefail

BUNDLE=/home/booklyn/cofunc-tdx
GENERIC_RUNNER=$BUNDLE/scripts/run_kata_tdx_cri_workload.sh
GATE=$BUNDLE/scripts/kata_tdx_host_safety_gate.sh
RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
WORKLOAD=fn_py_compression
EXPECTED_SAMPLES=20
run_root=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_compression_measurement_$(date -u +%Y%m%d_%H%M%S)}
batch_token=${RUN_TOKEN:-c25-$(date -u +%H%M%S)-$((BASHPID % 100))}
stop_re='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
log_loss_re='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages|[Ll]ost [0-9]+ kernel messages|messages dropped'
level2_re='CoFunc old-ABI TDX SEPT change:.*level=[2-9]|changed-live-split.*level=[2-9]|CoFunc TDX SEPT private lifecycle:.*level=[2-9]|CoFunc (old-ABI )?private TDP.*(level|iter_level|goal|req)=2|CoFunc TDX private TDP.*(level|iter_level)=2'
promotion_re='CoFunc old-ABI private 2M promotion|CoFunc.*private.*2M.*promot|CoFunc.*2M.*promot.*private'
active_phase=none
run_rc=125
final_gate_rc=125
evidence_rc=0
finished=0
completed_measured=0

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
	sudo -n dmesg --time-format iso >"$run_root/dmesg-$label.log"
}

capture_cri() {
	local label=$1
	sudo -n crictl --runtime-endpoint "$RUNTIME_ENDPOINT" ps -a -o json \
		>"$run_root/cri-containers-$label.json" 2>"$run_root/cri-containers-$label.stderr" || true
	sudo -n crictl --runtime-endpoint "$RUNTIME_ENDPOINT" pods -o json \
		>"$run_root/cri-pods-$label.json" 2>"$run_root/cri-pods-$label.stderr" || true
	ps -efww >"$run_root/processes-$label.txt"
}

make_delta() {
	local before_label=$1 after_label=$2 delta=$3

	[[ -r $run_root/dmesg-$before_label.log && -r $run_root/dmesg-$after_label.log ]] || \
		fail "missing dmesg snapshot while creating $delta"
	{ diff -u "$run_root/dmesg-$before_label.log" "$run_root/dmesg-$after_label.log" 2>/dev/null || true; } |
		sed -n '/^+[^+]/p' >"$delta"
}

check_delta() {
	local delta=$1 label=$2 safe_label

	safe_label=${label//\//_}
	[[ -r $delta ]] || fail "missing kernel delta for $label: $delta"
	if rg -n -i "$stop_re" "$delta" >"$run_root/${safe_label}-stop-markers.txt"; then
		fail "canonical KVM/TDX stop marker after $label"
	fi
	if rg -n -i "$log_loss_re" "$delta" >"$run_root/${safe_label}-log-loss.txt"; then
		fail "kernel log loss after $label"
	fi
	if rg -n -i "$level2_re" "$delta" >"$run_root/${safe_label}-private-level2.txt"; then
		fail "private level-2 mapping evidence after $label"
	fi
	if rg -n -i "$promotion_re" "$delta" >"$run_root/${safe_label}-private-2m-promotion.txt"; then
		fail "private 2M promotion evidence after $label"
	fi
}

verify_phase_no_leftovers() {
	local label=$1 safe_label file

	safe_label=${label//\//_}
	for file in "$run_root/cri-containers-$label-after.json" \
		"$run_root/cri-pods-$label-after.json" "$run_root/processes-$label-after.txt"; do
		if rg -n --fixed-strings "$batch_token" "$file" >"$run_root/${safe_label}-leftovers.txt"; then
			evidence_rc=1
			fail "run-token residue after $label"
		fi
	done
	: >"$run_root/${safe_label}-leftovers.txt"
}

verify_final_no_leftovers() {
	local file

	for file in "$run_root/cri-containers-after.json" "$run_root/cri-pods-after.json" "$run_root/processes-after.txt"; do
		if rg -n --fixed-strings "$batch_token" "$file" >"$run_root/final-leftovers.txt"; then
			evidence_rc=1
			return
		fi
	done
	: >"$run_root/final-leftovers.txt"
}

verify_sample_set() {
	local root="$run_root/log/$WORKLOAD" warmup_root="$run_root/warmup-log/$WORKLOAD"
	local iteration sample_dir sample_log count sample_dirs

	[[ -r "$root/kata_launch.log" ]] || {
		printf 'error: missing measured analyzer log\n' >&2
		return 1
	}
	count=$(jq -s 'length' "$root/kata_launch.log")
	[[ $count == "$EXPECTED_SAMPLES" ]] || {
		printf 'error: measured analyzer count mismatch: expected=%s actual=%s\n' \
			"$EXPECTED_SAMPLES" "$count" >&2
		return 1
	}
	sample_dirs=$(find "$root" -maxdepth 1 -mindepth 1 -type d -name 'sample-[0-9][0-9][0-9]' | wc -l)
	[[ $sample_dirs == "$EXPECTED_SAMPLES" ]] || {
		printf 'error: measured sample-directory count mismatch: expected=%s actual=%s\n' \
			"$EXPECTED_SAMPLES" "$sample_dirs" >&2
		return 1
	}
	jq -e -s --argjson expected "$EXPECTED_SAMPLES" '
		length == $expected and all(.[]; type == "object" and
			([.timestamp, .t_boot_cntr, .t_boot_func, .t_exec, .t_e2e] | all(type == "number")))
	' "$root/kata_launch.log" >/dev/null || {
		printf 'error: invalid measured analyzer JSON\n' >&2
		return 1
	}
	for ((iteration = 1; iteration <= EXPECTED_SAMPLES; iteration++)); do
		sample_dir="$root/$(printf 'sample-%03d' "$iteration")"
		sample_log="$sample_dir/container.log"
		[[ -r "$sample_dir/container-state.txt" && $(<"$sample_dir/container-state.txt") == CONTAINER_EXITED ]] || \
			{
				printf 'error: measured sample did not exit cleanly: %s\n' "$sample_dir" >&2
				return 1
			}
		[[ -r "$sample_dir/container-exit-code.txt" && $(<"$sample_dir/container-exit-code.txt") == 0 ]] || \
			{
				printf 'error: measured sample has non-zero exit: %s\n' "$sample_dir" >&2
				return 1
			}
		for marker in t_launch_begin t_import_begin t_func_load_begin t_import_done t_func_done; do
			rg -q "^${marker} [0-9]" "$sample_log" || {
				printf 'error: missing %s in %s\n' "$marker" "$sample_log" >&2
				return 1
			}
		done
	done
	[[ -r "$warmup_root/kata_launch.log" ]] || {
		printf 'error: missing untimed warm-up analyzer log\n' >&2
		return 1
	}
	[[ $(jq -s 'length' "$warmup_root/kata_launch.log") == 1 ]] || \
		{
			printf 'error: warm-up analyzer count is not one\n' >&2
			return 1
		}
	[[ -r "$warmup_root/sample-001/container-exit-code.txt" && \
		$(<"$warmup_root/sample-001/container-exit-code.txt") == 0 ]] || \
		{
			printf 'error: warm-up did not exit zero\n' >&2
			return 1
		}
}

run_prebuild() {
	active_phase=prebuild
	set +e
	RUN_DIR="$run_root/prebuild/attempt-001" \
	LOG_ROOT="$run_root/prebuild-log" \
	RUN_TOKEN="${batch_token}-prebuild" \
	PREPARE_ONLY=1 \
	SKIP_PREPARE=0 \
	RUNTIME_ENDPOINT="$RUNTIME_ENDPOINT" \
	"$GENERIC_RUNNER" "$WORKLOAD" 1
	run_rc=$?
	set -e
	(( run_rc == 0 )) || exit "$run_rc"
}

run_launch() {
	local label=$1 start_iteration=$2 log_root=$3 child_dir phase_rc delta

	active_phase=$label
	child_dir="$run_root/$label/attempt-001"
	delta="$run_root/${label}-dmesg-after.delta"
	capture_dmesg "$label-before"
	capture_cri "$label-before"
	set +e
	RUN_DIR="$child_dir" \
	LOG_ROOT="$log_root" \
	RUN_TOKEN="${batch_token}-${label}" \
	PREPARE_ONLY=0 \
	SKIP_PREPARE=1 \
	START_ITERATION="$start_iteration" \
	RUNTIME_ENDPOINT="$RUNTIME_ENDPOINT" \
	"$GENERIC_RUNNER" "$WORKLOAD" 1
	phase_rc=$?
	set -e
	capture_dmesg "$label-after"
	capture_cri "$label-after"
	make_delta "$label-before" "$label-after" "$delta"
	check_delta "$delta" "$label"
	verify_phase_no_leftovers "$label"
	if (( phase_rc != 0 )); then
		run_rc=$phase_rc
		exit "$phase_rc"
	fi
}

finish() {
	local entry_rc=$? final_rc

	(( finished == 0 )) || return
	finished=1
	trap - EXIT
	set +e
	if [[ -r $run_root/dmesg-before.log ]]; then
		capture_dmesg after
		if [[ -r $run_root/dmesg-after.log ]]; then
			{ diff -u "$run_root/dmesg-before.log" "$run_root/dmesg-after.log" 2>/dev/null || true; } |
				sed -n '/^+[^+]/p' >"$run_root/dmesg-after.delta"
		else
			: >"$run_root/dmesg-after.delta"
			evidence_rc=1
		fi
	else
		: >"$run_root/dmesg-after.delta"
		evidence_rc=1
	fi
	capture_cri after
	sudo -n "$GATE" post-0025-compression-measurement 2>&1 | tee "$run_root/postflight.log"
	final_gate_rc=${PIPESTATUS[0]}
	if [[ -r $run_root/dmesg-after.delta ]]; then
		rg -n -i "$stop_re|$log_loss_re|$level2_re|$promotion_re" \
			"$run_root/dmesg-after.delta" >"$run_root/final-prohibited-kernel-markers.txt" && evidence_rc=1
	else
		evidence_rc=1
	fi
	verify_final_no_leftovers
	if (( run_rc == 0 )); then
		verify_sample_set || evidence_rc=1
	fi
	{
		printf 'run_rc=%d\n' "$run_rc"
		printf 'postflight_gate_rc=%d\n' "$final_gate_rc"
		printf 'evidence_rc=%d\n' "$evidence_rc"
		printf 'harness_entry_rc=%d\n' "$entry_rc"
		printf 'active_phase=%s\n' "$active_phase"
		printf 'completed_measured=%d\n' "$completed_measured"
		printf 'run_root=%s\n' "$run_root"
		printf 'batch_token=%s\n' "$batch_token"
	} >"$run_root/harness-result.txt"
	printf 'run_root=%s\n' "$run_root"
	printf 'run_rc=%d postflight_gate_rc=%d evidence_rc=%d\n' \
		"$run_rc" "$final_gate_rc" "$evidence_rc"

	final_rc=$entry_rc
	(( run_rc == 0 )) || final_rc=$run_rc
	(( final_gate_rc == 0 )) || final_rc=$final_gate_rc
	(( evidence_rc == 0 )) || final_rc=$evidence_rc
	exit "$final_rc"
}

for command in curl crictl diff dmesg find jq ps rg sed sha256sum tee wc; do
	need "$command"
done
[[ -x $GENERIC_RUNNER ]] || fail "missing generic CRI runner: $GENERIC_RUNNER"
[[ -x $GATE ]] || fail "missing host-safety gate: $GATE"
(( ${#batch_token} <= 13 )) || fail "RUN_TOKEN must be at most 13 characters: $batch_token"
sudo -n true 2>/dev/null || fail "sudo credentials are not cached; run sudo -v and retry"
[[ ! -e $run_root ]] || fail "refusing to reuse run root: $run_root"
mkdir -p "$run_root"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'run_root=%s\n' "$run_root"
	printf 'batch_token=%s\n' "$batch_token"
	printf 'workload=%s\n' "$WORKLOAD"
	printf 'untimed_warmups=1\n'
	printf 'measured_cold_samples=%d\n' "$EXPECTED_SAMPLES"
	printf 'generic_runner=%s\n' "$GENERIC_RUNNER"
	printf 'aggregation_log_root=%s\n' "$run_root/log"
	printf 'graphs=disabled\n'
} >"$run_root/compression-measurement-command.txt"
cp "$0" "$run_root/harness.sh"
sha256sum "$0" >"$run_root/harness.sha256"

sudo -n "$GATE" pre-0025-compression-measurement-launch | tee "$run_root/preflight.log"
{
	curl --connect-timeout 5 --max-time 15 -fsS -X POST \
		http://127.0.0.1:8888/get_param \
		--data-urlencode "fn_name=testcases/$WORKLOAD" >/dev/null
	printf 'parameter=%s ready\n' "$WORKLOAD"
	curl --connect-timeout 5 --max-time 15 -fsS \
		http://127.0.0.1:9000/minio/health/ready >/dev/null
	printf 'minio=127.0.0.1:9000 ready\n'
} >"$run_root/helpers-ready.txt"

{
	printf 'kernel=%s\n' "$(uname -r)"
	printf 'kvm_srcversion=%s\n' "$(< /sys/module/kvm/srcversion)"
	printf 'kvm_intel_srcversion=%s\n' "$(< /sys/module/kvm_intel/srcversion)"
	printf 'kvm_intel_tdx=%s\n' "$(< /sys/module/kvm_intel/parameters/tdx)"
	printf 'tdp_mmu=%s\n' "$(< /sys/module/kvm/parameters/tdp_mmu)"
	sudo -n df -B1 /Serverless
} >"$run_root/module-identities-and-capacity.txt"

# Preparation validates helpers, stages input, builds/imports the image, and
# pins the CRI image. It does not create a CRI pod and is outside all timings.
run_prebuild
capture_dmesg before
capture_cri before

run_launch warmup 1 "$run_root/warmup-log"
for iteration in $(seq 1 "$EXPECTED_SAMPLES"); do
	label=$(printf 'measured-%03d' "$iteration")
	run_launch "$label" "$iteration" "$run_root/log"
	completed_measured=$iteration
done

active_phase=none
run_rc=0
exit 0
