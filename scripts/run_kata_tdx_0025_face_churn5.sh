#!/usr/bin/env bash
# One-shot patch-0025 containment churn harness.  This invokes the generic
# workload runner exactly once for five cold face launches and preserves the
# surrounding host evidence.  It does not retry.
set -Eeuo pipefail

BUNDLE=/home/booklyn/cofunc-tdx
RUNNER=$BUNDLE/scripts/run_kata_tdx_cri_workload.sh
GATE=$BUNDLE/scripts/kata_tdx_host_safety_gate.sh
RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
run_dir=${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_face_churn5_$(date -u +%Y%m%d_%H%M%S)}
run_token=${RUN_TOKEN:-f11-0025-churn5-$(date -u +%H%M%S)-$$}
runner_rc=125
final_gate_rc=125
finished=0

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

capture_dmesg() {
	local label=$1
	sudo -n dmesg --time-format iso >"$run_dir/dmesg-$label.log"
}

capture_cri() {
	local label=$1
	sudo -n crictl --runtime-endpoint "$RUNTIME_ENDPOINT" ps -a -o json \
		>"$run_dir/cri-containers-$label.json" 2>"$run_dir/cri-containers-$label.stderr" || true
	sudo -n crictl --runtime-endpoint "$RUNTIME_ENDPOINT" pods -o json \
		>"$run_dir/cri-pods-$label.json" 2>"$run_dir/cri-pods-$label.stderr" || true
	ps -ef >"$run_dir/processes-$label.txt"
}

finish() {
	local rc=$? final_rc

	(( finished == 0 )) || return
	finished=1
	set +e
	capture_dmesg after
	diff -u "$run_dir/dmesg-before.log" "$run_dir/dmesg-after.log" 2>/dev/null |
		sed -n '/^+[^+]/p' >"$run_dir/dmesg-after.delta"
	capture_cri after
	sudo -n "$GATE" post-0025-churn 2>&1 | tee "$run_dir/postflight.log"
	final_gate_rc=${PIPESTATUS[0]}
	{
		printf 'runner_rc=%d\n' "$runner_rc"
		printf 'postflight_gate_rc=%d\n' "$final_gate_rc"
		printf 'harness_entry_rc=%d\n' "$rc"
		printf 'run_dir=%s\n' "$run_dir"
		printf 'run_token=%s\n' "$run_token"
	} >"$run_dir/harness-result.txt"
	printf 'run_dir=%s\n' "$run_dir"
	printf 'runner_rc=%d postflight_gate_rc=%d\n' "$runner_rc" "$final_gate_rc"

	final_rc=$rc
	(( runner_rc == 0 )) || final_rc=$runner_rc
	(( final_gate_rc == 0 )) || final_rc=$final_gate_rc
	exit "$final_rc"
}

for command in curl crictl diff dmesg ps sed sha256sum tee; do
	need "$command"
done
[[ -x $RUNNER ]] || die "missing generic runner: $RUNNER"
[[ -x $GATE ]] || die "missing host-safety gate: $GATE"
sudo -n true 2>/dev/null || die "sudo credentials are not cached; run sudo -v and retry"
[[ ! -e $run_dir ]] || die "refusing to reuse run directory: $run_dir"
mkdir -p "$run_dir"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'run_dir=%s\n' "$run_dir"
	printf 'run_token=%s\n' "$run_token"
	printf 'workload=fn_py_face_detection\n'
	printf 'repetitions=5\n'
	printf 'generic_runner=%s\n' "$RUNNER"
	printf 'generic_invocation=RUN_DIR=%s RUN_TOKEN=%s %s fn_py_face_detection 5\n' \
		"$run_dir" "$run_token" "$RUNNER"
} >"$run_dir/churn-command.txt"
cp "$0" "$run_dir/harness.sh"

sudo -n "$GATE" pre-0025-churn-launch | tee "$run_dir/preflight.log"
curl --connect-timeout 5 --max-time 15 -fsS -X POST \
	http://127.0.0.1:8888/get_param \
	--data-urlencode fn_name=testcases/fn_py_face_detection >/dev/null
curl --connect-timeout 5 --max-time 15 -fsS \
	http://127.0.0.1:9000/minio/health/ready >/dev/null

{
	printf 'kernel=%s\n' "$(uname -r)"
	printf 'kvm_srcversion=%s\n' "$(< /sys/module/kvm/srcversion)"
	printf 'kvm_intel_srcversion=%s\n' "$(< /sys/module/kvm_intel/srcversion)"
	printf 'kvm_intel_tdx=%s\n' "$(< /sys/module/kvm_intel/parameters/tdx)"
	printf 'tdp_mmu=%s\n' "$(< /sys/module/kvm/parameters/tdp_mmu)"
} >"$run_dir/module-identities.txt"

capture_cri before
capture_dmesg before

set +e
RUN_DIR="$run_dir" RUN_TOKEN="$run_token" \
	"$RUNNER" fn_py_face_detection 5
runner_rc=$?
set -e
exit "$runner_rc"
