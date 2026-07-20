#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
RUNNER="$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh"
CVM_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0006-Diagnostic-expose-guest-accept-pgfault-stats.patch"
RUNTIME_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT="${OUT:-$ROOT/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_$STAMP}"

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -x "$RUNNER" ]] || die "missing runner: $RUNNER"
	[[ -f "$CVM_PATCH" ]] || die "missing CVM instrumentation patch: $CVM_PATCH"
	[[ -f "$RUNTIME_PATCH" ]] || die "missing runtime instrumentation patch: $RUNTIME_PATCH"

	log "running old-ABI TDX runtime diagnostic with grant/accept instrumentation: $OUT"
	export OUT
	export COFUNC_OLDABI_CVM_EXTRA_PATCH="$CVM_PATCH"
	export COFUNC_OLDABI_RUNTIME_EXTRA_PATCH="$RUNTIME_PATCH"
	"$RUNNER" "$@"
}

main "$@"
