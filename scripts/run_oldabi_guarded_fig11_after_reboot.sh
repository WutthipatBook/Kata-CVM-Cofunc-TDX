#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT="${OUT:-$ROOT/results/oldabi_guarded_fig11_after_reboot_$STAMP}"
GUARD_DIR="$OUT/guard"
PREFLIGHT="$BUNDLE/scripts/oldabi_tdx_host_preflight.sh"
HUGEPAGE_PROBE="$BUNDLE/scripts/run_oldabi_hugepage_only_probe.sh"
FIG11_RUNNER="$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh"
PROBE_WORKLOAD="${COFUNC_GUARD_PROBE_WORKLOAD:-chain_js_alexa/fn_js_alexa_frontend}"
SMOKE_OUT="$GUARD_DIR/fig11-smoke"
POST_SMOKE_CHURN_MB="${COFUNC_GUARD_POST_SMOKE_CHURN_MB:-1024}"
STOP_AFTER_SMOKE_CHURN="${COFUNC_GUARD_STOP_AFTER_SMOKE_CHURN:-0}"
STOP_MARKERS='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|Unknown SEAMCALL status code\(0xc0000b0d|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_EPT_WALK_FAILED|TDX_PAGE_METADATA_INCORRECT|tdx_sept_zap_private_spte|tdx_reclaim_page'

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

ensure_rw() {
	findmnt /mnt/new_disk >/dev/null || die "/mnt/new_disk is not mounted"
	local opts
	opts="$(findmnt -no OPTIONS /mnt/new_disk)"
	if [[ ,$opts, == *,ro,* ]]; then
		log "remounting /mnt/new_disk read-write"
		mount -o remount,rw /mnt/new_disk
	fi
	opts="$(findmnt -no OPTIONS /mnt/new_disk)"
	[[ ,$opts, == *,rw,* ]] || die "/mnt/new_disk is not read-write: $opts"
}

scan_stop_markers() {
	local label=$1
	local dir=$2
	local log_file="$GUARD_DIR/${label}.stop-markers.log"

	: >"$log_file"
	if [[ -d $dir ]] && rg -n \
		--glob '!**/guard-env.txt' \
		--glob '!**/*.stop-markers.log' \
		"$STOP_MARKERS" "$dir" >"$log_file" 2>/dev/null; then
		cat "$log_file" >&2
		die "$label produced kernel/TDX stop markers; leaving results at $OUT"
	fi
}

run_preflight() {
	local label=$1
	local log_file="$GUARD_DIR/preflight-${label}.log"

	log "running old-ABI host preflight: $label"
	if "$PREFLIGHT" >"$log_file" 2>&1; then
		cat "$log_file"
	else
		cat "$log_file" >&2
		die "preflight failed before $label; refusing to run old-ABI TDX workload"
	fi
}

run_post_smoke_churn() {
	local log_file="$GUARD_DIR/post-smoke-churn.log"

	log "running post-smoke allocation churn: ${POST_SMOKE_CHURN_MB} MiB"
	python3 - "$POST_SMOKE_CHURN_MB" >"$log_file" 2>&1 <<'PY'
import sys

mb = int(sys.argv[1])
page = 4096
chunks = []
for _ in range(mb):
    b = bytearray(1024 * 1024)
    for off in range(0, len(b), page):
        b[off] = 1
    chunks.append(b)
print(f"allocated_and_touched_mib={mb}")
chunks.clear()
print("released=1")
PY
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -x "$PREFLIGHT" ]] || die "missing preflight: $PREFLIGHT"
	[[ -x "$HUGEPAGE_PROBE" ]] || die "missing hugepage probe: $HUGEPAGE_PROBE"
	[[ -x "$FIG11_RUNNER" ]] || die "missing Fig. 11 runner: $FIG11_RUNNER"
	if [[ ${COFUNC_OLDABI_REGULAR_MEMFILE:-0} != 0 ]]; then
		die "COFUNC_OLDABI_REGULAR_MEMFILE must be unset/0 for paper-faithful guarded Fig. 11"
	fi

	ensure_rw
	mkdir -p "$GUARD_DIR"
	{
		echo "out=$OUT"
		echo "probe_workload=$PROBE_WORKLOAD"
		echo "preflight=$PREFLIGHT"
		echo "hugepage_probe=$HUGEPAGE_PROBE"
		echo "fig11_runner=$FIG11_RUNNER"
		echo "fig11_smoke_out=$SMOKE_OUT"
		echo "post_smoke_churn_mb=$POST_SMOKE_CHURN_MB"
		echo "stop_after_smoke_churn=$STOP_AFTER_SMOKE_CHURN"
		echo "stop_markers=$STOP_MARKERS"
	} >"$GUARD_DIR/guard-env.txt"

	run_preflight "before-hugepage-probe"

	local safe_probe="${PROBE_WORKLOAD//\//_}"
	local probe_out="$GUARD_DIR/hugepage-probe-$safe_probe"
	log "running hugepage allocation probe: $PROBE_WORKLOAD"
	OUT="$probe_out" "$HUGEPAGE_PROBE" "$PROBE_WORKLOAD" \
		>"$GUARD_DIR/hugepage-probe.log" 2>&1 \
		|| {
			cat "$GUARD_DIR/hugepage-probe.log" >&2
			die "hugepage allocation probe failed; refusing Fig. 11"
		}
	scan_stop_markers "hugepage-probe" "$probe_out"

	run_preflight "before-fig11-smoke"

	log "running Fig. 11 smoke gate: fn_py_face_detection x1"
	STOP_AFTER_SMOKE=1 OUT="$SMOKE_OUT" "$FIG11_RUNNER" \
		>"$GUARD_DIR/fig11-smoke.log" 2>&1 \
		|| {
			cat "$GUARD_DIR/fig11-smoke.log" >&2
			scan_stop_markers "fig11-smoke-failed" "$SMOKE_OUT" || true
			die "Fig. 11 smoke gate failed; refusing full Fig. 11"
		}
	scan_stop_markers "fig11-smoke" "$SMOKE_OUT"

	run_post_smoke_churn
	run_preflight "after-fig11-smoke-churn"
	if [[ $STOP_AFTER_SMOKE_CHURN != 0 ]]; then
		log "stopping after smoke/churn gate: $OUT"
		return 0
	fi

	run_preflight "before-fig11"

	log "running paper-faithful old-ABI Fig. 11: $OUT"
	COFUNC_OLDABI_REGULAR_MEMFILE=0 COFUNC_OLDABI_SKIP_FACE_SMOKE=1 OUT="$OUT" "$FIG11_RUNNER" \
		>"$GUARD_DIR/fig11-runner.log" 2>&1 \
		|| {
			cat "$GUARD_DIR/fig11-runner.log" >&2
			scan_stop_markers "fig11-failed" "$OUT" || true
			die "Fig. 11 runner failed; see $OUT"
		}
	scan_stop_markers "fig11" "$OUT"

	run_preflight "after-fig11"
	log "guarded Fig. 11 completed cleanly: $OUT"
}

main "$@"
