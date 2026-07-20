#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
RUNNER="$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh"
THP_ENABLED="/sys/kernel/mm/transparent_hugepage/enabled"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
OUT="${OUT:-$ROOT/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_thp_never_$STAMP}"

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

record_state() {
	local label=$1
	mkdir -p "$OUT"
	printf '%s=%s\n' "$label" "$(cat "$THP_ENABLED")" >>"$OUT/thp-wrapper-state.txt"
}

record_value() {
	local label=$1 value=$2
	mkdir -p "$OUT"
	printf '%s=%s\n' "$label" "$value" >>"$OUT/thp-wrapper-state.txt"
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -x "$RUNNER" ]] || die "missing runner: $RUNNER"
	[[ -w "$THP_ENABLED" ]] || die "cannot write $THP_ENABLED"

	local before restore_mode cleanup_done=0
	before="$(active_token "$THP_ENABLED")"
	[[ -n $before ]] || die "could not parse active THP mode from $THP_ENABLED"
	restore_mode="${COFUNC_THP_RESTORE_MODE:-$before}"
	record_state "before"
	record_value "restore_mode" "$restore_mode"
	if [[ $before == never && -z ${COFUNC_THP_RESTORE_MODE:-} ]]; then
		log "warning: THP was already never; cleanup will restore never"
	fi

	cleanup() {
		local rc=${1:-$?} restore_rc
		if (( cleanup_done )); then
			exit "$rc"
		fi
		cleanup_done=1
		set +e
		trap - EXIT INT TERM HUP
		log "restoring transparent_hugepage/enabled=$restore_mode"
		printf '%s\n' "$restore_mode" >"$THP_ENABLED"
		restore_rc=$?
		record_value "restore_write_rc" "$restore_rc"
		record_state "after"
		if (( restore_rc != 0 )); then
			log "warning: failed to restore transparent_hugepage/enabled=$restore_mode (rc=$restore_rc)"
		fi
		exit "$rc"
	}
	trap 'cleanup $?' EXIT
	trap 'cleanup 130' INT
	trap 'cleanup 143' TERM
	trap 'cleanup 129' HUP

	log "setting transparent_hugepage/enabled=never for diagnostic run (was $before)"
	printf '%s\n' never >"$THP_ENABLED"
	record_state "during"

	export OUT
	set +e
	"$RUNNER" "$@"
	local rc=$?
	set -e
	cleanup "$rc"
}

main "$@"
