#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
RUNNER="$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh"
CVM_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0006-Diagnostic-expose-guest-accept-pgfault-stats.patch"
RUNTIME_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch"
THP_ENABLED="/sys/kernel/mm/transparent_hugepage/enabled"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT="${OUT:-$ROOT/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_instrumented_thp_never_$STAMP}"

active_token() {
	sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1"
}

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -x "$RUNNER" ]] || die "missing instrumented runner: $RUNNER"
	[[ -f "$CVM_PATCH" ]] || die "missing CVM instrumentation patch: $CVM_PATCH"
	[[ -f "$RUNTIME_PATCH" ]] || die "missing runtime instrumentation patch: $RUNTIME_PATCH"
	[[ -w "$THP_ENABLED" ]] || die "cannot write $THP_ENABLED"

	local before restore_mode cleanup_done=0
	before="$(active_token "$THP_ENABLED")"
	[[ -n $before ]] || die "could not parse active THP mode from $THP_ENABLED"
	restore_mode="${COFUNC_THP_RESTORE_MODE:-$before}"
	mkdir -p "$OUT"
	{
		printf 'before=%s\n' "$(cat "$THP_ENABLED")"
		printf 'restore_mode=%s\n' "$restore_mode"
	} >>"$OUT/thp-wrapper-state.txt"

	cleanup() {
		local rc=${1:-$?} restore_rc
		if ((cleanup_done)); then
			exit "$rc"
		fi
		cleanup_done=1
		set +e
		trap - EXIT INT TERM HUP
		log "restoring transparent_hugepage/enabled=$restore_mode"
		printf '%s\n' "$restore_mode" >"$THP_ENABLED"
		restore_rc=$?
		{
			printf 'restore_write_rc=%s\n' "$restore_rc"
			printf 'after=%s\n' "$(cat "$THP_ENABLED")"
		} >>"$OUT/thp-wrapper-state.txt"
		if ((restore_rc != 0)); then
			log "warning: failed to restore transparent_hugepage/enabled=$restore_mode (rc=$restore_rc)"
		fi
		exit "$rc"
	}
	trap 'cleanup $?' EXIT
	trap 'cleanup 130' INT
	trap 'cleanup 143' TERM
	trap 'cleanup 129' HUP

	log "running old-ABI TDX runtime diagnostic with THP disabled and grant/accept instrumentation: $OUT"
	printf '%s\n' never >"$THP_ENABLED"
	printf 'during=%s\n' "$(cat "$THP_ENABLED")" >>"$OUT/thp-wrapper-state.txt"

	export OUT
	export COFUNC_OLDABI_CVM_EXTRA_PATCH="$CVM_PATCH"
	export COFUNC_OLDABI_RUNTIME_EXTRA_PATCH="$RUNTIME_PATCH"
	set +e
	"$RUNNER" "$@"
	local rc=$?
	set -e
	cleanup "$rc"
}

main "$@"
