#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARTIFACT="/mnt/nvme_500g/cofunc_tdx_artifact/cofunc-artifact"
OUT=""
WORKLOADS="fn_py_face_detection,fn_py_image_processing,fn_py_sentiment,fn_py_video_processing,fn_py_compression,fn_py_dna_visualisation,fn_js_uploader,fn_js_thumbnailer,chain_js_alexa"
PREPARE_PERFORMANCE=1
CORE_ISOLATED=1
STRICT=0
JSON_OUT=""
RUN_ARGS=()

usage() {
	cat <<'EOF'
Usage:
  scripts/run_tdx_fig11_pdf_compare.sh [options]

Runs the CoFunc TDX fork E2E experiment for the Fig. 11 workloads from the
paper PDF, then compares measured E2E latency against approximate TDX CoFunc
bars digitized from the log-scale PDF.

Defaults are paper-check oriented:
  --prepare-performance is enabled
  --core-isolated is enabled
  workload subset is the 9 representative Fig. 11 groups

Options:
  --artifact PATH          CoFunc artifact root
  --out PATH               Output directory
  --workloads LIST         Comma-separated workload/app names
  --skip-build             Pass through to run_tdx_sc_fork_e2e.sh
  --keep-going             Pass through to run_tdx_sc_fork_e2e.sh
  --keep-helpers           Pass through to run_tdx_sc_fork_e2e.sh
  --no-cleanup             Pass through to run_tdx_sc_fork_e2e.sh
  --no-stop-conflicts      Pass through to run_tdx_sc_fork_e2e.sh
  --no-prepare-performance Do not set CPU governor/EPP before running
  --no-core-isolated       Do not require/pin to boot-isolated CPUs
  --taskset-cpus LIST      Pass through workload affinity
  --tdx-smp N|auto         Pass through TDX guest vCPU count
  --tdx-vm-cooldown SEC    Pass through inter-workload TDX VM cooldown
  --kvm-create-vm-retries N
                           Pass through KVM_CREATE_VM busy retry count
  --kvm-create-vm-cooldown SEC
                           Pass through KVM_CREATE_VM busy retry cooldown
  --workload-timeout SEC   Pass through stuck workload timeout; 0 disables
  --quiet-workload-output  Pass through quiet workload console logging
  --json PATH              Write paper-check JSON to PATH
  --strict                 Make the final comparison exit nonzero on FAIL
  -h, --help               Show this help

Outputs:
  tdx_sc_fork_summary.txt  Measured run summary
  paper-check.txt          Host/artifact/result audit plus PDF-bar comparison
  paper-check.json         Machine-readable audit, unless --json overrides path
  fig11-breakdown.md/json  Fig. 11 and Table 3-like breakdown from sc_fork logs
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

while (($#)); do
	case "$1" in
		--artifact)
			ARTIFACT=${2:?missing value for --artifact}
			shift 2
			;;
		--out)
			OUT=${2:?missing value for --out}
			shift 2
			;;
		--workloads)
			WORKLOADS=${2:?missing value for --workloads}
			shift 2
			;;
		--skip-build|--keep-going|--keep-helpers|--no-cleanup|--no-stop-conflicts|--quiet-workload-output)
			RUN_ARGS+=("$1")
			shift
			;;
		--no-prepare-performance)
			PREPARE_PERFORMANCE=0
			shift
			;;
		--no-core-isolated)
			CORE_ISOLATED=0
			shift
			;;
		--taskset-cpus)
			RUN_ARGS+=("$1" "${2:?missing value for --taskset-cpus}")
			shift 2
			;;
		--tdx-smp|--tdx-vm-cooldown|--kvm-create-vm-retries|--kvm-create-vm-cooldown|--workload-timeout)
			RUN_ARGS+=("$1" "${2:?missing value for $1}")
			shift 2
			;;
		--json)
			JSON_OUT=${2:?missing value for --json}
			shift 2
			;;
		--strict)
			STRICT=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

[[ -x "$SCRIPT_DIR/run_tdx_sc_fork_e2e.sh" ]] || die "missing run_tdx_sc_fork_e2e.sh"
[[ -x "$SCRIPT_DIR/cofunc_tdx_paper_check.py" ]] || die "missing executable cofunc_tdx_paper_check.py"
[[ -x "$SCRIPT_DIR/cofunc_tdx_breakdown_compare.py" ]] || die "missing executable cofunc_tdx_breakdown_compare.py"

ARTIFACT=$(realpath "$ARTIFACT")
if [[ -z $OUT ]]; then
	OUT="/home/ljhhasang/perf_proto/results/tdx_fig11_pdf_compare_$(date -u +%Y%m%d_%H%M%S)"
fi
OUT=$(realpath -m "$OUT")
if [[ -z $JSON_OUT ]]; then
	JSON_OUT="$OUT/paper-check.json"
fi

paper_check_args=(
	--artifact "$ARTIFACT"
	--results "$OUT"
	--json "$JSON_OUT"
)
if [[ $STRICT == 1 ]]; then
	paper_check_args+=(--strict)
fi

run_args=(
	--artifact "$ARTIFACT"
	--out "$OUT"
	--workloads "$WORKLOADS"
)
if [[ $PREPARE_PERFORMANCE == 1 ]]; then
	run_args+=(--prepare-performance)
else
	run_args+=(--require-performance)
fi
if [[ $CORE_ISOLATED == 1 ]]; then
	run_args+=(--core-isolated)
fi
run_args+=("${RUN_ARGS[@]}")

mkdir -p "$OUT"
{
	printf 'artifact=%s\n' "$ARTIFACT"
	printf 'workloads=%s\n' "$WORKLOADS"
	printf 'prepare_performance=%s\n' "$PREPARE_PERFORMANCE"
	printf 'core_isolated=%s\n' "$CORE_ISOLATED"
	printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'target_source=%s\n' "paper PDF Fig. 11 TDX CoFunc bars, digitized approximate"
} >"$OUT/fig11-pdf-compare-run.txt"

log "running TDX Fig. 11 workload subset"
"$SCRIPT_DIR/run_tdx_sc_fork_e2e.sh" "${run_args[@]}"

log "comparing measured results against digitized PDF bars"
"$SCRIPT_DIR/cofunc_tdx_paper_check.py" "${paper_check_args[@]}" | tee "$OUT/paper-check.txt"

log "writing Fig. 11 breakdown report"
"$SCRIPT_DIR/cofunc_tdx_breakdown_compare.py" \
	--results "$OUT" \
	--markdown "$OUT/fig11-breakdown.md" \
	--json "$OUT/fig11-breakdown.json" \
	>"$OUT/fig11-breakdown.txt"

log "done: $OUT"
