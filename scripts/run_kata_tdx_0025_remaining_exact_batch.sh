#!/usr/bin/env bash
# Collect the six remaining Vanilla Kata-TDX Fig. 11 workloads using the
# artifact-exact sampling rule: exactly 20 fresh cold launches per workload,
# with no discarded warm-up. Each workload is validated and its generated CRI
# image references are synchronously removed before the next workload starts.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
EXACT_HARNESS=$BUNDLE/scripts/run_kata_tdx_0025_exact_measurement.sh
CLEANUP=$BUNDLE/scripts/cleanup_kata_tdx_measured_workload_image.sh
GATE=$BUNDLE/scripts/kata_tdx_host_safety_gate.sh
SAMPLES=20
batch_root=${BATCH_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_0025_remaining_exact_batch_$(date -u +%Y%m%d_%H%M%S)}
workloads=(
	fn_js_thumbnailer
	fn_js_uploader
	chain_js_alexa/fn_js_alexa_frontend
	chain_js_alexa/fn_js_alexa_interact
	chain_js_alexa/fn_js_alexa_smarthome
	chain_js_alexa/fn_js_alexa_tv
)

active_workload=none
completed_workloads=0
batch_rc=125
final_gate_rc=125
finished=0

fail() {
	batch_rc=1
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

run_gate() {
	local context=$1 output=$2 gate_rc

	set +e
	sudo -n "$GATE" "$context" 2>&1 | tee "$output"
	gate_rc=${PIPESTATUS[0]}
	set -e
	if (( gate_rc != 0 )) || ! rg -q '^host_safety=ready$' "$output"; then
		return 1
	fi
}

finish() {
	local entry_rc=$? final_rc

	(( finished == 0 )) || return
	finished=1
	trap - EXIT
	set +e
	if run_gate post-0025-remaining-exact-batch "$batch_root/postflight.log"; then
		final_gate_rc=0
	else
		final_gate_rc=$?
	fi
	{
		printf 'batch_rc=%d\n' "$batch_rc"
		printf 'postflight_gate_rc=%d\n' "$final_gate_rc"
		printf 'entry_rc=%d\n' "$entry_rc"
		printf 'active_workload=%s\n' "$active_workload"
		printf 'completed_workloads=%d\n' "$completed_workloads"
		printf 'planned_workloads=%d\n' "${#workloads[@]}"
		printf 'samples_per_workload=%d\n' "$SAMPLES"
		printf 'batch_root=%s\n' "$batch_root"
	} >"$batch_root/batch-result.txt"
	printf 'batch_root=%s\n' "$batch_root"
	printf 'batch_rc=%d postflight_gate_rc=%d completed_workloads=%d/%d\n' \
		"$batch_rc" "$final_gate_rc" "$completed_workloads" "${#workloads[@]}"

	final_rc=$entry_rc
	(( batch_rc == 0 )) || final_rc=$batch_rc
	(( final_gate_rc == 0 )) || final_rc=$final_gate_rc
	exit "$final_rc"
}

for command in date jq rg sha256sum sudo tee; do
	need "$command"
done
[[ -x $EXACT_HARNESS ]] || fail "missing exact measurement harness: $EXACT_HARNESS"
[[ -x $CLEANUP ]] || fail "missing measured-image cleanup script: $CLEANUP"
[[ -x $GATE ]] || fail "missing host-safety gate: $GATE"
sudo -n true 2>/dev/null || fail "sudo credentials are not cached; run sudo -v and retry"
[[ ! -e $batch_root ]] || fail "refusing to reuse batch root: $batch_root"
mkdir -p "$batch_root" "$batch_root/measurements" "$batch_root/cleanups" \
	"$batch_root/workload-summaries"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'batch_root=%s\n' "$batch_root"
	printf 'sampling_rule=artifact-first-N\n'
	printf 'excluded_warmups=0\n'
	printf 'cold_samples_per_workload=%d\n' "$SAMPLES"
	printf 'retry_policy=none\n'
	printf 'resume_policy=none\n'
	printf 'graph_generation=disabled\n'
	printf 'exact_harness=%s\n' "$EXACT_HARNESS"
	printf 'cleanup_script=%s\n' "$CLEANUP"
	printf 'workloads_begin\n'
	printf '%s\n' "${workloads[@]}"
	printf 'workloads_end\n'
} >"$batch_root/batch-plan.txt"
sha256sum "$0" "$EXACT_HARNESS" "$CLEANUP" "$GATE" >"$batch_root/script-inputs.sha256"

run_gate pre-0025-remaining-exact-batch "$batch_root/preflight.log" ||
	fail "initial host-safety gate is not ready"

for index in "${!workloads[@]}"; do
	workload=${workloads[$index]}
	ordinal=$((index + 1))
	safe_workload=${workload//\//_}
	measurement_root=$batch_root/measurements/$safe_workload
	cleanup_root=$batch_root/cleanups/$safe_workload
	run_token=$(printf 'r25-%02d-%s' "$ordinal" "$(date -u +%H%M%S)")
	measurement_log=$batch_root/${safe_workload}-measurement.stdout.log
	cleanup_log=$batch_root/${safe_workload}-cleanup.stdout.log
	active_workload=$workload

	printf '[%s] workload=%s phase=measurement samples=%d\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$workload" "$SAMPLES" |
		tee -a "$batch_root/progress.log"
	set +e
	RUN_ROOT="$measurement_root" RUN_TOKEN="$run_token" \
		"$EXACT_HARNESS" "$workload" "$SAMPLES" 2>&1 | tee "$measurement_log"
	measurement_rc=${PIPESTATUS[0]}
	set -e
	(( measurement_rc == 0 )) || fail "measurement failed for $workload: rc=$measurement_rc"
	[[ -r $measurement_root/harness-result.txt ]] ||
		fail "missing harness result for $workload"
	for expected in run_rc=0 postflight_gate_rc=0 evidence_rc=0 \
		"completed_measured=$SAMPLES"; do
		rg -qx --fixed-strings "$expected" "$measurement_root/harness-result.txt" ||
			fail "measurement validation failed for $workload: missing $expected"
	done

	printf '[%s] workload=%s phase=cleanup\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$workload" |
		tee -a "$batch_root/progress.log"
	set +e
	sudo -n env EVIDENCE_ROOT="$cleanup_root" "$CLEANUP" "$measurement_root" \
		2>&1 | tee "$cleanup_log"
	cleanup_rc=${PIPESTATUS[0]}
	set -e
	(( cleanup_rc == 0 )) || fail "image cleanup failed for $workload: rc=$cleanup_rc"
	rg -q '^cleanup_status=passed$' "$cleanup_log" ||
		fail "cleanup did not report success for $workload"

	analyzer_log=$measurement_root/log/$workload/kata_launch.log
	[[ -r $analyzer_log ]] || fail "missing analyzer log for $workload"
	analyzer_count=$(jq -s 'length' "$analyzer_log")
	mean_e2e=$(jq -s 'map(.t_e2e) | add / length' "$analyzer_log")
	[[ $analyzer_count == "$SAMPLES" ]] ||
		fail "analyzer count changed for $workload: $analyzer_count"
	{
		printf 'workload=%s\n' "$workload"
		printf 'measurement_root=%s\n' "$measurement_root"
		printf 'cleanup_root=%s\n' "$cleanup_root"
		printf 'sampling_rule=artifact-first-N\n'
		printf 'excluded_warmups=0\n'
		printf 'cold_samples=%s\n' "$analyzer_count"
		printf 'mean_t_e2e=%s\n' "$mean_e2e"
		printf 'measurement_rc=%d\n' "$measurement_rc"
		printf 'cleanup_rc=%d\n' "$cleanup_rc"
		sha256sum "$measurement_root/harness-result.txt" \
			"$measurement_root/harness.sha256" "$cleanup_root/SHA256SUMS"
	} >"$batch_root/workload-summaries/$safe_workload.txt"
	completed_workloads=$ordinal
	printf '[%s] workload=%s status=passed completed=%d/%d mean_t_e2e=%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$workload" \
		"$completed_workloads" "${#workloads[@]}" "$mean_e2e" |
		tee -a "$batch_root/progress.log"
done

active_workload=none
batch_rc=0
exit 0
