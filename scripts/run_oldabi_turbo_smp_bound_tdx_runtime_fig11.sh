#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"

export STOP_AFTER_SMOKE="${STOP_AFTER_SMOKE:-0}"
export OUT="${OUT:-$ROOT/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_fig11_$STAMP}"

exec "$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh" "$@"
