#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
RUNNER="$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_fig11.sh"
CVM_PATCH="${COFUNC_OLDABI_CVM_INSTRUMENTATION_PATCH:-$BUNDLE/patches/cofunc-artifact-oldabi/0006-Diagnostic-expose-guest-accept-pgfault-stats.patch}"
RUNTIME_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0007-Diagnostic-emit-grant-accept-runtime-metrics.patch"
RUNTIME_FOLLOWUP_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0012-Preserve-Python-syscall-binding-across-workload-exec.patch"
RUNTIME_METRICS_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0014-Report-page-fault-count-and-calibrated-time.patch"
RUNTIME_TRACE_PATCH="${COFUNC_OLDABI_RUNTIME_TRACE_PATCH:-}"
COUNT_SOURCE_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0013-Count-first-level-page-faults-atomically.patch"
COUNT_SOURCE_FILES=(
	"$ROOT/cofunc-artifact-oldabi/cvm_os/kernel/arch/x86_64/irq/irq_entry.c"
	"$ROOT/cofunc-artifact-oldabi/cvm_os/kernel/include/object/cap_group.h"
	"$ROOT/cofunc-artifact-oldabi/cvm_os/kernel/split-container/snapshot.c"
	"$ROOT/cofunc-artifact-oldabi/cvm_os/kernel/split-container/split_container.c"
)
KERNEL_ISO="$ROOT/cofunc-artifact-oldabi/cvm_os/build/kernel/arch/x86_64/boot/intel_tdx/chcore.iso"
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
	[[ -f "$RUNTIME_FOLLOWUP_PATCH" ]] || die "missing runtime instrumentation follow-up patch: $RUNTIME_FOLLOWUP_PATCH"
	[[ -f "$RUNTIME_METRICS_PATCH" ]] || die "missing calibrated page-fault metrics patch: $RUNTIME_METRICS_PATCH"
	if [[ -n $RUNTIME_TRACE_PATCH ]]; then
		[[ -f "$RUNTIME_TRACE_PATCH" ]] || die "missing handler trace patch: $RUNTIME_TRACE_PATCH"
	fi
	[[ -f "$COUNT_SOURCE_PATCH" ]] || die "missing page-fault count source patch: $COUNT_SOURCE_PATCH"
	[[ -f "$KERNEL_ISO" ]] || die "missing rebuilt kernel ISO: $KERNEL_ISO"
	local source_file
	for source_file in "${COUNT_SOURCE_FILES[@]}"; do
		[[ -f "$source_file" ]] || die "missing page-fault count source: $source_file"
		[[ "$KERNEL_ISO" -nt "$source_file" ]] \
			|| die "kernel ISO predates $source_file; apply patch 0013 and rebuild before launching"
	done
	rg -q 'unsigned long sc_n_pgfault' "${COUNT_SOURCE_FILES[1]}" \
		|| die "page-fault count field is absent; apply $COUNT_SOURCE_PATCH before launching"
	rg -q '__sync_fetch_and_add\(&current_cap_group->sc_n_pgfault, 1\)' "${COUNT_SOURCE_FILES[0]}" \
		|| die "atomic page-fault count update is absent; apply $COUNT_SOURCE_PATCH before launching"
	rg -q 'dst_cap_group->sc_n_pgfault = 0' "${COUNT_SOURCE_FILES[2]}" \
		|| die "copied cap-group count reset is absent; apply $COUNT_SOURCE_PATCH before launching"

	log "running old-ABI TDX runtime diagnostic with grant/accept instrumentation: $OUT"
	export OUT
	export COFUNC_OLDABI_CVM_EXTRA_PATCH="$CVM_PATCH"
	export COFUNC_OLDABI_RUNTIME_EXTRA_PATCH="$RUNTIME_PATCH"
	export COFUNC_OLDABI_RUNTIME_FOLLOWUP_PATCH="$RUNTIME_FOLLOWUP_PATCH"
	export COFUNC_OLDABI_RUNTIME_METRICS_PATCH="$RUNTIME_METRICS_PATCH"
	export COFUNC_OLDABI_RUNTIME_TRACE_PATCH="$RUNTIME_TRACE_PATCH"
	"$RUNNER" "$@"
}

main "$@"
