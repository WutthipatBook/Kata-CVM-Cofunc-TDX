#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT/cofunc-artifact}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
RUN_DIR="${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_fig11_$STAMP}"
LOG_DIR="$RUN_DIR/log"
RUN_LOG="$RUN_DIR/runner.log"
WORKLOAD_RUN_LOG="$RUN_DIR/workload-runner.log"
PREFLIGHT="$BUNDLE/scripts/kata_tdx_preflight.sh"
WORKLOAD_RUNNER="$BUNDLE/scripts/run_kata_tdx_workload.sh"
STAGE_BREAKDOWN="$BUNDLE/scripts/cofunc_e2e_stage_breakdown.py"
STAGE_CHARTS="$BUNDLE/scripts/cofunc_e2e_stage_bar_charts.py"
IMAGE_DIR="${IMAGE_DIR:-/home/booklyn/BookArchive/Images}"
KATA_CONFIG="${KATA_CONFIG:-$BUNDLE/configs/configuration-qemu-tdx-artifact-qemu7-debug.toml}"
TDX_QEMU="${TDX_QEMU:-$BUNDLE/scripts/qemu_tdx_oldabi_wrapper.sh}"
TDX_FIRMWARE="${TDX_FIRMWARE:-$ROOT/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd}"
KATA_QEMU_WRAPPER_LOG="${KATA_QEMU_WRAPPER_LOG:-$RUN_DIR/qemu-wrapper.log}"
KATA_RUN_TIMEOUT="${KATA_RUN_TIMEOUT:-600}"
KATA_RETRIES="${KATA_RETRIES:-2}"
KATA_RETRY_COOLDOWN_SEC="${KATA_RETRY_COOLDOWN_SEC:-20}"
STOP_AFTER_SMOKE="${STOP_AFTER_SMOKE:-0}"
INCLUDE_KATA_DNA="${INCLUDE_KATA_DNA:-1}"

BASE_WORKLOADS=(
	"fn_py_compression 20"
	"fn_py_face_detection 20"
	"fn_py_image_processing 20"
	"fn_py_sentiment 20"
	"fn_py_video_processing 5"
	"fn_js_thumbnailer 20"
	"fn_js_uploader 20"
	"chain_js_alexa/fn_js_alexa_frontend 20"
	"chain_js_alexa/fn_js_alexa_interact 20"
	"chain_js_alexa/fn_js_alexa_smarthome 20"
	"chain_js_alexa/fn_js_alexa_tv 20"
)

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

check_ready() {
	[[ -x "$PREFLIGHT" ]] || die "missing preflight: $PREFLIGHT"
	[[ -x "$WORKLOAD_RUNNER" ]] || die "missing workload runner: $WORKLOAD_RUNNER"
	[[ -x "$STAGE_BREAKDOWN" ]] || die "missing stage summarizer: $STAGE_BREAKDOWN"
	[[ -x "$STAGE_CHARTS" ]] || die "missing stage chart renderer: $STAGE_CHARTS"
	[[ -d "$ARTIFACT_DIR" ]] || die "missing artifact dir: $ARTIFACT_DIR"
	[[ $KATA_RETRIES =~ ^[0-9]+$ && $KATA_RETRIES -gt 0 ]] || die "invalid KATA_RETRIES=$KATA_RETRIES"
	[[ $KATA_RETRY_COOLDOWN_SEC =~ ^[0-9]+$ ]] || die "invalid KATA_RETRY_COOLDOWN_SEC=$KATA_RETRY_COOLDOWN_SEC"
	if ! sudo -n true 2>/dev/null; then
		die "sudo credentials are not cached; run sudo -v first"
	fi
}

run_preflight() {
	local label=$1
	local log_file="$RUN_DIR/preflight-$label.log"

	log "running Kata-TDX preflight: $label"
	if KATA_CONFIG="$KATA_CONFIG" \
		TDX_QEMU="$TDX_QEMU" \
		TDX_FIRMWARE="$TDX_FIRMWARE" \
		"$PREFLIGHT" >"$log_file" 2>&1; then
		cat "$log_file"
	else
		cat "$log_file" >&2
		die "Kata-TDX preflight failed at $label"
	fi
}

run_workload() {
	local workload=$1
	local times=$2
	local attempt rc

	for ((attempt = 1; attempt <= KATA_RETRIES; attempt++)); do
		log "running vanilla Kata-TDX workload=$workload times=$times attempt=$attempt/$KATA_RETRIES"
		set +e
		ARTIFACT_DIR="$ARTIFACT_DIR" \
		LOG_DIR="$LOG_DIR" \
		RUN_LOG="$WORKLOAD_RUN_LOG" \
		KATA_CONFIG="$KATA_CONFIG" \
		TDX_QEMU="$TDX_QEMU" \
		TDX_FIRMWARE="$TDX_FIRMWARE" \
		KATA_QEMU_WRAPPER_LOG="$KATA_QEMU_WRAPPER_LOG" \
		KATA_RUN_TIMEOUT="$KATA_RUN_TIMEOUT" \
		"$WORKLOAD_RUNNER" "$workload" "$times"
		rc=$?
		set -e
		if ((rc == 0)); then
			return 0
		fi
		log "vanilla Kata-TDX workload failed: workload=$workload rc=$rc"
		if ((attempt < KATA_RETRIES)); then
			log "waiting ${KATA_RETRY_COOLDOWN_SEC}s before retry"
			sleep "$KATA_RETRY_COOLDOWN_SEC"
		fi
	done
	return "$rc"
}

render_graphs() {
	local stem="kata_tdx_vanilla_fig11_${STAMP}"
	local json="$IMAGE_DIR/stage_breakdown_${stem}.json"
	local csv="$IMAGE_DIR/stage_breakdown_${stem}.csv"
	local md="$IMAGE_DIR/stage_breakdown_${stem}.md"
	local prefix="fig11-kata-tdx-vanilla-${STAMP}"

	log "generating vanilla Kata-TDX stage breakdown"
	"$STAGE_BREAKDOWN" \
		--log-root "$LOG_DIR" \
		--markdown "$md" \
		--csv "$csv" \
		--json "$json" \
		>"$RUN_DIR/stage-breakdown.log"

	log "rendering vanilla Kata-TDX stage graphs"
	"$STAGE_CHARTS" \
		--input "$json" \
		--out-dir "$IMAGE_DIR" \
		--prefix "$prefix" \
		--title-prefix "Vanilla Kata TDX Fig. 11" \
		--views full startup \
		>"$RUN_DIR/stage-graphs.log"
	cat "$RUN_DIR/stage-graphs.log"
}

main() {
	local workloads=("${BASE_WORKLOADS[@]}")
	if [[ $INCLUDE_KATA_DNA == 1 ]]; then
		workloads=("fn_py_dna_visualisation 10" "${workloads[@]}")
	elif [[ $INCLUDE_KATA_DNA != 0 ]]; then
		die "INCLUDE_KATA_DNA must be 0 or 1, got $INCLUDE_KATA_DNA"
	fi

	mkdir -p "$RUN_DIR" "$LOG_DIR"
	exec > >(tee -a "$RUN_LOG") 2>&1

	check_ready
	{
		echo "run_dir=$RUN_DIR"
		echo "log_dir=$LOG_DIR"
		echo "artifact_dir=$ARTIFACT_DIR"
		echo "kata_config=$KATA_CONFIG"
		echo "kata_runtime_name=${KATA_RUNTIME_NAME:-kata-qemu-tdx}"
		echo "tdx_qemu=$TDX_QEMU"
		echo "tdx_firmware=$TDX_FIRMWARE"
		echo "kata_qemu_wrapper_log=$KATA_QEMU_WRAPPER_LOG"
		echo "kata_run_timeout=$KATA_RUN_TIMEOUT"
		echo "kata_retries=$KATA_RETRIES"
		echo "include_kata_dna=$INCLUDE_KATA_DNA"
		printf 'workloads='
		printf '%s;' "${workloads[@]}"
		printf '\n'
	} >"$RUN_DIR/run-env.txt"

	run_preflight "before-smoke"
	run_workload "fn_py_face_detection" 1

	if [[ $STOP_AFTER_SMOKE == 1 ]]; then
		log "STOP_AFTER_SMOKE=1, stopping after smoke"
		return 0
	fi

	run_preflight "before-fig11"
	local entry workload times
	for entry in "${workloads[@]}"; do
		workload="${entry% *}"
		times="${entry##* }"
		run_workload "$workload" "$times"
	done
	run_preflight "after-fig11"
	render_graphs
	log "vanilla Kata-TDX Fig. 11 completed: $RUN_DIR"
}

main "$@"
