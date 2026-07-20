#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
RUNNER="$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT="${OUT:-$ROOT/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_4k_accept_$STAMP}"

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

	log "running old-ABI TDX runtime diagnostic with split-container accept forced to 4K: $OUT"
	export OUT
	export COFUNC_OLDABI_FORCE_4K_ACCEPT=1
	"$RUNNER" "$@"
}

main "$@"
