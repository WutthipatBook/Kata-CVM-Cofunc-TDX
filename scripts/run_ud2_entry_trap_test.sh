#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
RUN_DIR="$BUNDLE/logs/ud2-entry-trap-$STAMP"
BUILD_LOG="$RUN_DIR/probe_build.log"
DIAG_LOG="$RUN_DIR/diag_terminal.log"
CLEANUP_LOG="$RUN_DIR/cleanup.log"
OUT="$ROOT/results/oldqemu_chcore_ud2_entry_$STAMP"

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

cleanup() {
	local rc=$?
	if [[ ${COFUNC_SKIP_FINAL_CLEANUP:-0} == 1 ]]; then
		log "COFUNC_SKIP_FINAL_CLEANUP=1; leaving diagnostic artifact in place"
		exit "$rc"
	fi

	log "running final diagnostic cleanup"
	set +e
	"$BUNDLE/scripts/cleanup_current_tdx_diagnostics.sh" 2>&1 \
		| tee "$CLEANUP_LOG" "$BUNDLE/last_cleanup.log"
	local cleanup_rc=${PIPESTATUS[0]}
	set -e
	if ((cleanup_rc != 0)); then
		log "cleanup failed rc=$cleanup_rc; see $CLEANUP_LOG"
		exit "$cleanup_rc"
	fi
	log "cleanup complete"
	exit "$rc"
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -x "$BUNDLE/scripts/apply_current_early_probe_build.sh" ]] \
		|| die "missing apply helper"
	[[ -x "$BUNDLE/scripts/boot_oldqemu_chcore_diag.sh" ]] \
		|| die "missing boot diagnostic helper"
	[[ -x "$BUNDLE/scripts/cleanup_current_tdx_diagnostics.sh" ]] \
		|| die "missing cleanup helper"

	mkdir -p "$RUN_DIR"
	trap cleanup EXIT

	log "run directory: $RUN_DIR"
	log "boot output: $OUT"
	log "building UD2 entry-trap diagnostic ISO"
	COFUNC_ENTRY_TRAP=1 "$BUNDLE/scripts/apply_current_early_probe_build.sh" 2>&1 \
		| tee "$BUILD_LOG" "$BUNDLE/last_probe_build.log"

	log "running old-QEMU TDX boot diagnostic before cleanup"
	set +e
	OUT="$OUT" \
	LAUNCH_MODE=artifact-fg \
	COFUNC_QEMU_STRACE=1 \
	COFUNC_QEMU_NO_REBOOT=0 \
	COFUNC_QEMU_DEBUG=1 \
	COFUNC_CVM_BOOT_TIMEOUT="${COFUNC_CVM_BOOT_TIMEOUT:-30}" \
	COFUNC_TDX_OVMF="${COFUNC_TDX_OVMF:-$ROOT/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd}" \
	"$BUNDLE/scripts/boot_oldqemu_chcore_diag.sh" 2>&1 \
		| tee "$DIAG_LOG" "$BUNDLE/last_diag_terminal.log"
	local diag_rc=${PIPESTATUS[0]}
	set -e
	log "boot diagnostic helper rc=$diag_rc"

	if [[ -f "$OUT/current-trace/current-serial.log" ]]; then
		log "serial summary"
		for pat in "[GRUB probe] before multiboot2" "[GRUB probe] gfxpayload=" \
			"WARNING: no console will be available to OS" "[GRUB probe] after multiboot2" \
			"[GRUB probe] before boot" "[GRUB probe] boot returned" "[ASM0]" "[ASM1]" "[ChCore probe]" "[ChCore]"; do
			printf '%s=' "$pat"
			LC_ALL=C grep -aF "$pat" "$OUT/current-trace/current-serial.log" | wc -l
		done
	fi

	if [[ -f "$OUT/current-trace/current-qemu-debug.log" ]]; then
		log "qemu-debug exception/fault summary"
		LC_ALL=C rg -n 'exception|fault|check_exception|v=06|UD|invalid|triple|shutdown|CPU Reset' \
			"$OUT/current-trace/current-qemu-debug.log" | head -n 80 || true
	fi

	log "test artifacts:"
	log "  run dir: $RUN_DIR"
	log "  boot out: $OUT"
}

main "$@"
