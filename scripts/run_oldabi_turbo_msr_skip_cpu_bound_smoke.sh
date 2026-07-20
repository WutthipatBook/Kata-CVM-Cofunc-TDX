#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
ARTIFACT="$ROOT/cofunc-artifact-oldabi"
TURBO_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0001-Skip-TDX-MISC-ENABLE-wrmsr-diagnostic.patch"
CPU_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0002-Bound-old-ABI-SMP-startup-to-MADT-cpu-count.patch"
FORCE_4K_ACCEPT_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0005-Diagnostic-force-4K-split-container-accept.patch"
EXTRA_CVM_PATCH="${COFUNC_OLDABI_CVM_EXTRA_PATCH:-}"
RUNNER="$BUNDLE/scripts/run_oldabi_5_19_fig11.sh"
TDX_C="$ARTIFACT/cvm_os/kernel/arch/x86_64/plat/intel_tdx/tdx.c"
SMP_C="$ARTIFACT/cvm_os/kernel/arch/x86_64/machine/smp.c"
MADT_C="$ARTIFACT/cvm_os/kernel/arch/x86_64/drivers/acpi/madt.c"
ACPI_H="$ARTIFACT/cvm_os/kernel/include/arch/x86_64/arch/drivers/acpi.h"
SPLIT_C="$ARTIFACT/cvm_os/kernel/split-container/split_container.c"
ISO="$ARTIFACT/cvm_os/build/chcore.iso"
KERNEL_BUILD="$ARTIFACT/cvm_os/build/kernel"
KERNEL_IMG="$KERNEL_BUILD/kernel.img"
KERNEL_ISO="$KERNEL_BUILD/arch/x86_64/boot/intel_tdx/chcore.iso"
TDX_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/arch/x86_64/plat/intel_tdx/tdx.c.obj"
SMP_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/arch/x86_64/machine/smp.c.obj"
MADT_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/arch/x86_64/drivers/acpi/madt.c.obj"
SPLIT_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/split-container/split_container.c.obj"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BUNDLE/backups/oldabi-turbo-smp-bound-$STAMP"
OUT="${OUT:-$ROOT/results/oldabi_5_19_turbo_smp_bound_smoke_$STAMP}"
STOP_AFTER_SMOKE_VALUE="${STOP_AFTER_SMOKE:-1}"
FORCE_4K_ACCEPT_VALUE="${COFUNC_OLDABI_FORCE_4K_ACCEPT:-0}"
DIAG_MARKERS='CoFunc diag|skip TDX WRMSR|TDX WRMSR failed|get_cpu_count|force 4K split-container accept|CoFunc grant/accept stat instrumentation'
backup_done=0

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

hash_state() {
	local path
	for path in "$TDX_C" "$SMP_C" "$MADT_C" "$ACPI_H" "$SPLIT_C" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO"; do
		[[ -e "$path" ]] && sha256sum "$path"
	done
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

cleanup() {
	local rc=$?
	set +e
	if ((backup_done)); then
		log "restoring old-ABI source and boot images"
		cp -a "$BACKUP_DIR/tdx.c.before" "$TDX_C"
		cp -a "$BACKUP_DIR/smp.c.before" "$SMP_C"
		cp -a "$BACKUP_DIR/madt.c.before" "$MADT_C"
		cp -a "$BACKUP_DIR/acpi.h.before" "$ACPI_H"
		cp -a "$BACKUP_DIR/split_container.c.before" "$SPLIT_C"
		[[ -f "$BACKUP_DIR/kernel.img.before" ]] && cp -a "$BACKUP_DIR/kernel.img.before" "$KERNEL_IMG"
		if [[ -f "$BACKUP_DIR/kernel-chcore.iso.before" ]]; then
			cp -a "$BACKUP_DIR/kernel-chcore.iso.before" "$KERNEL_ISO"
		else
			rm -f "$KERNEL_ISO"
		fi
		[[ -f "$BACKUP_DIR/chcore.iso.before" ]] && cp -a "$BACKUP_DIR/chcore.iso.before" "$ISO"
		rm -f "$TDX_OBJ" "$SMP_OBJ" "$MADT_OBJ" "$SPLIT_OBJ"
		hash_state >"$BACKUP_DIR/sha256.restored"
		if rg -q "$DIAG_MARKERS" "$TDX_C" "$SMP_C" "$MADT_C" "$ACPI_H" "$SPLIT_C"; then
			log "warning: diagnostic marker still present after restore"
		fi
		log "restore evidence: $BACKUP_DIR"
	fi
	exit "$rc"
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -d "$ARTIFACT/cvm_os" ]] || die "missing artifact CVM OS: $ARTIFACT/cvm_os"
	[[ -f "$TURBO_PATCH" ]] || die "missing patch: $TURBO_PATCH"
	[[ -f "$CPU_PATCH" ]] || die "missing patch: $CPU_PATCH"
	[[ -f "$FORCE_4K_ACCEPT_PATCH" ]] || die "missing patch: $FORCE_4K_ACCEPT_PATCH"
	if [[ -n $EXTRA_CVM_PATCH ]]; then
		[[ -f "$EXTRA_CVM_PATCH" ]] || die "missing extra CVM patch: $EXTRA_CVM_PATCH"
	fi
	[[ -x "$RUNNER" ]] || die "missing old-ABI runner: $RUNNER"
	[[ -f "$TDX_C" ]] || die "missing TDX source: $TDX_C"
	[[ -f "$SMP_C" ]] || die "missing SMP source: $SMP_C"
	[[ -f "$MADT_C" ]] || die "missing MADT source: $MADT_C"
	[[ -f "$ACPI_H" ]] || die "missing ACPI header: $ACPI_H"
	[[ -f "$SPLIT_C" ]] || die "missing split-container source: $SPLIT_C"
	[[ -d "$KERNEL_BUILD" ]] || die "missing kernel build dir: $KERNEL_BUILD"
	[[ -f "$KERNEL_IMG" ]] || die "missing kernel image: $KERNEL_IMG"
	[[ -f "$ISO" ]] || die "missing runtime ISO: $ISO"
	[[ $FORCE_4K_ACCEPT_VALUE == 0 || $FORCE_4K_ACCEPT_VALUE == 1 ]] \
		|| die "COFUNC_OLDABI_FORCE_4K_ACCEPT must be 0 or 1, got $FORCE_4K_ACCEPT_VALUE"

	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$TDX_C" "$BACKUP_DIR/tdx.c.before"
	cp -a "$SMP_C" "$BACKUP_DIR/smp.c.before"
	cp -a "$MADT_C" "$BACKUP_DIR/madt.c.before"
	cp -a "$ACPI_H" "$BACKUP_DIR/acpi.h.before"
	cp -a "$SPLIT_C" "$BACKUP_DIR/split_container.c.before"
	cp -a "$KERNEL_IMG" "$BACKUP_DIR/kernel.img.before"
	[[ -f "$KERNEL_ISO" ]] && cp -a "$KERNEL_ISO" "$BACKUP_DIR/kernel-chcore.iso.before"
	cp -a "$ISO" "$BACKUP_DIR/chcore.iso.before"
	hash_state >"$BACKUP_DIR/sha256.before"
	backup_done=1
	trap cleanup EXIT

	{
		printf 'cofunc_oldabi_force_4k_accept=%s\n' "$FORCE_4K_ACCEPT_VALUE"
		printf 'cofunc_oldabi_cvm_extra_patch=%s\n' "$EXTRA_CVM_PATCH"
	} >"$BACKUP_DIR/options"

	if rg -q "$DIAG_MARKERS" "$TDX_C" "$SMP_C" "$MADT_C" "$ACPI_H" "$SPLIT_C"; then
		die "diagnostic marker is already present; refusing to stack patches"
	fi

	log "applying old-ABI TDX WRMSR diagnostic patch"
	patch -d "$ARTIFACT" -p1 -i "$TURBO_PATCH"
	log "applying old-ABI SMP CPU-count bound patch"
	patch -d "$ARTIFACT" -p1 -i "$CPU_PATCH"
	if [[ $FORCE_4K_ACCEPT_VALUE == 1 ]]; then
		log "applying old-ABI split-container 4K accept diagnostic patch"
		patch -d "$ARTIFACT" -p1 -i "$FORCE_4K_ACCEPT_PATCH"
	fi
	if [[ -n $EXTRA_CVM_PATCH ]]; then
		log "applying extra old-ABI CVM diagnostic patch: $EXTRA_CVM_PATCH"
		patch -d "$ARTIFACT" -p1 -i "$EXTRA_CVM_PATCH"
	fi

	log "removing stale old-ABI build outputs"
	rm -f "$TDX_OBJ" "$SMP_OBJ" "$MADT_OBJ" "$SPLIT_OBJ" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO"

	log "building old-ABI ChCore ISO with WRMSR skip and SMP CPU-count bound"
	(
		cd "$KERNEL_BUILD"
		cmake --build . --target chcore.iso --parallel "$(nproc)"
	)

	[[ -f "$KERNEL_IMG" ]] || die "build did not produce $KERNEL_IMG"
	[[ -f "$KERNEL_ISO" || -f "$ISO" ]] || die "build produced neither $KERNEL_ISO nor $ISO"
	[[ -f "$KERNEL_ISO" ]] && cp -a "$KERNEL_ISO" "$ISO"
	[[ -f "$ISO" ]] || die "build did not produce $ISO"

	LC_ALL=C grep -aFq "[CoFunc diag] skip TDX WRMSR 0x1a0" "$KERNEL_IMG" \
		|| die "rebuilt kernel.img does not contain diagnostic WRMSR skip marker"
	LC_ALL=C grep -aFq "[CoFunc diag] skip TDX WRMSR 0x1a0" "$ISO" \
		|| die "rebuilt chcore.iso does not contain diagnostic WRMSR skip marker"
	if ! LC_ALL=C objdump -t "$KERNEL_IMG" >"$BACKUP_DIR/kernel.img.symbols"; then
		die "objdump could not read rebuilt kernel.img symbol table"
	fi
	if ! grep -Fq "get_cpu_count" "$BACKUP_DIR/kernel.img.symbols"; then
		die "rebuilt kernel.img does not contain get_cpu_count symbol"
	fi
	hash_state >"$BACKUP_DIR/sha256.diagnostic"
	cp -a "$KERNEL_IMG" "$BACKUP_DIR/kernel.img.diagnostic"
	[[ -f "$KERNEL_ISO" ]] && cp -a "$KERNEL_ISO" "$BACKUP_DIR/kernel-chcore.iso.diagnostic"
	cp -a "$ISO" "$BACKUP_DIR/chcore.iso.diagnostic"

	log "running old-ABI workload set with diagnostic ISO: $OUT stop_after_smoke=$STOP_AFTER_SMOKE_VALUE"
	STOP_AFTER_SMOKE="$STOP_AFTER_SMOKE_VALUE" OUT="$OUT" "$RUNNER"
	log "diagnostic workload set completed: $OUT"
}

main "$@"
