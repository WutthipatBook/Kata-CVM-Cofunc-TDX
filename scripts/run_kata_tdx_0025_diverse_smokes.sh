#!/usr/bin/env bash
# One-shot patch-0025 diverse smoke harness. Each workload gets an independent
# Fig. 11 smoke run so private level-2 evidence can stop the batch immediately.
set -Eeuo pipefail

BUNDLE=/home/booklyn/cofunc-tdx
RUNNER=$BUNDLE/scripts/run_kata_tdx_cri_fig11.sh
GATE=$BUNDLE/scripts/kata_tdx_host_safety_gate.sh
RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
run_root=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_diverse_smokes_$(date -u +%Y%m%d_%H%M%S)}
batch_token=${RUN_TOKEN:-d25-$(date -u +%H%M%S)-$((BASHPID % 1000))}
workloads=(
	fn_py_dna_visualisation
	fn_py_video_processing
	chain_js_alexa/fn_js_alexa_interact
)
level2_re='CoFunc TDX SEPT private lifecycle:.*level=[2-9]|CoFunc TDX private TDP level diagnostic:.*(level|iter_level)=2|CoFunc old-ABI private 2M promotion'
stop_re='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
log_loss_re='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages'
active_workload=none
run_rc=125
final_gate_rc=125
evidence_rc=0
finished=0
completed_workloads=()
workload_index=0

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
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
	ps -ef >"$run_root/processes-$label.txt"
}

check_delta() {
	local delta=$1 workload=$2

	[[ -r $delta ]] || die "missing kernel delta for $workload: $delta"
	if rg -n -i "$stop_re" "$delta" | tee "$run_root/${workload//\//_}-stop-markers.txt"; then
		die "kernel/KVM/TDX stop marker after $workload"
	fi
	if rg -n -i "$log_loss_re" "$delta" | tee "$run_root/${workload//\//_}-log-loss.txt"; then
		die "kernel log loss after $workload"
	fi
	if rg -n -i "$level2_re" "$delta" | tee "$run_root/${workload//\//_}-private-level2.txt"; then
		die "private level-2 mapping evidence after $workload"
	fi
}

finish() {
	local entry_rc=$? final_rc

	(( finished == 0 )) || return
	finished=1
	trap - EXIT
	set +e
	capture_dmesg after
	diff -u "$run_root/dmesg-before.log" "$run_root/dmesg-after.log" 2>/dev/null |
		sed -n '/^+[^+]/p' >"$run_root/dmesg-after.delta"
	capture_cri after
	sudo -n "$GATE" post-0025-diverse-smokes 2>&1 | tee "$run_root/postflight.log"
	final_gate_rc=${PIPESTATUS[0]}
	if rg -n -i "$stop_re|$log_loss_re|$level2_re" "$run_root/dmesg-after.delta" \
		>"$run_root/final-prohibited-kernel-markers.txt"; then
		evidence_rc=1
	fi
	{
		printf 'run_rc=%d\n' "$run_rc"
		printf 'postflight_gate_rc=%d\n' "$final_gate_rc"
		printf 'evidence_rc=%d\n' "$evidence_rc"
		printf 'harness_entry_rc=%d\n' "$entry_rc"
		printf 'active_workload=%s\n' "$active_workload"
		printf 'completed_workloads=%s\n' "${completed_workloads[*]:-}"
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

for command in curl crictl diff dmesg ps rg sed tee; do
	need "$command"
done
[[ -x $RUNNER ]] || die "missing Fig. 11 runner: $RUNNER"
[[ -x $GATE ]] || die "missing host-safety gate: $GATE"
((${#batch_token} <= 16)) || die "RUN_TOKEN must be at most 16 characters: $batch_token"
sudo -n true 2>/dev/null || die "sudo credentials are not cached; run sudo -v and retry"
[[ ! -e $run_root ]] || die "refusing to reuse run root: $run_root"
mkdir -p "$run_root"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'run_root=%s\n' "$run_root"
	printf 'batch_token=%s\n' "$batch_token"
	printf 'workloads=%s\n' "${workloads[*]}"
	printf 'runner=%s\n' "$RUNNER"
} >"$run_root/diverse-smokes-command.txt"
cp "$0" "$run_root/harness.sh"

sudo -n "$GATE" pre-0025-diverse-smokes-launch | tee "$run_root/preflight.log"
for workload in "${workloads[@]}"; do
	curl --connect-timeout 5 --max-time 15 -fsS -X POST \
		http://127.0.0.1:8888/get_param \
		--data-urlencode "fn_name=testcases/$workload" >/dev/null
done
curl --connect-timeout 5 --max-time 15 -fsS \
	http://127.0.0.1:9000/minio/health/ready >/dev/null

{
	printf 'kernel=%s\n' "$(uname -r)"
	printf 'kvm_srcversion=%s\n' "$(< /sys/module/kvm/srcversion)"
	printf 'kvm_intel_srcversion=%s\n' "$(< /sys/module/kvm_intel/srcversion)"
	printf 'kvm_intel_tdx=%s\n' "$(< /sys/module/kvm_intel/parameters/tdx)"
	printf 'tdp_mmu=%s\n' "$(< /sys/module/kvm/parameters/tdp_mmu)"
} >"$run_root/module-identities.txt"

capture_cri before
capture_dmesg before

for workload in "${workloads[@]}"; do
	active_workload=$workload
	safe_workload=${workload//\//_}
	workload_dir="$run_root/smokes/$safe_workload"
	((++workload_index))
	set +e
	RUN_DIR="$workload_dir" \
	RUN_TOKEN="${batch_token}-w${workload_index}" \
	FIG11_MODE=smokes \
	FIG11_WORKLOADS="$workload" \
	"$RUNNER"
	run_rc=$?
	set -e
	(( run_rc == 0 )) || exit "$run_rc"
	check_delta "$workload_dir/dmesg-after.delta" "$workload"
	completed_workloads+=("$workload")
done

active_workload=none
run_rc=0
exit 0
