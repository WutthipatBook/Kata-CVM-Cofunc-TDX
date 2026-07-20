#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
ARTIFACT="$ROOT/cofunc-artifact"
MAIN_C="$ARTIFACT/cvm_os/kernel/arch/x86_64/main.c"
HEADER_S="$ARTIFACT/cvm_os/kernel/arch/x86_64/boot/intel_tdx/init/header.S"
GRUB_CFG="$ARTIFACT/cvm_os/kernel/arch/x86_64/boot/intel_tdx/iso/boot/grub/grub.cfg"
ISO="$ARTIFACT/cvm_os/build/chcore.iso"
KERNEL_BUILD="$ARTIFACT/cvm_os/build/kernel"
KERNEL_IMG="$KERNEL_BUILD/kernel.img"
KERNEL_ISO="$KERNEL_BUILD/arch/x86_64/boot/intel_tdx/chcore.iso"
MAIN_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/arch/x86_64/main.c.obj"
HEADER_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/arch/x86_64/boot/intel_tdx/init/header.S.obj"

MAIN_CLEAN="$BUNDLE/backups/current-early-probe-20260624_080639/main.c.before"
HEADER_CLEAN="$BUNDLE/backups/current-early-probe-20260624_085524/header.S.before"
GRUB_CLEAN="$BUNDLE/backups/current-early-probe-20260626_042534/grub.cfg.before"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
CLEANUP_BACKUP="$BUNDLE/backups/current-diagnostic-cleanup-$STAMP"

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
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -f "$MAIN_CLEAN" ]] || die "missing clean main.c backup: $MAIN_CLEAN"
	[[ -f "$HEADER_CLEAN" ]] || die "missing clean header.S backup: $HEADER_CLEAN"
	[[ -f "$GRUB_CLEAN" ]] || die "missing clean grub.cfg backup: $GRUB_CLEAN"
	[[ -d "$KERNEL_BUILD" ]] || die "missing kernel build dir: $KERNEL_BUILD"

	ensure_rw
	mkdir -p "$CLEANUP_BACKUP"
	cp -a "$MAIN_C" "$CLEANUP_BACKUP/main.c.before-cleanup"
	cp -a "$HEADER_S" "$CLEANUP_BACKUP/header.S.before-cleanup"
	cp -a "$GRUB_CFG" "$CLEANUP_BACKUP/grub.cfg.before-cleanup"
	[[ -f "$KERNEL_IMG" ]] && cp -a "$KERNEL_IMG" "$CLEANUP_BACKUP/kernel.img.before-cleanup"
	[[ -f "$KERNEL_ISO" ]] && cp -a "$KERNEL_ISO" "$CLEANUP_BACKUP/kernel-chcore.iso.before-cleanup"
	[[ -f "$ISO" ]] && cp -a "$ISO" "$CLEANUP_BACKUP/chcore.iso.before-cleanup"
	sha256sum "$MAIN_C" "$HEADER_S" "$GRUB_CFG" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO" 2>/dev/null \
		| tee "$CLEANUP_BACKUP/sha256.before-cleanup"

	log "restoring pre-diagnostic source files"
	cp -a "$MAIN_CLEAN" "$MAIN_C"
	cp -a "$HEADER_CLEAN" "$HEADER_S"
	cp -a "$GRUB_CLEAN" "$GRUB_CFG"

	log "removing stale diagnostic build outputs"
	rm -f "$MAIN_OBJ" "$HEADER_OBJ" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO"

	log "rebuilding clean current ChCore ISO"
	(
		cd "$KERNEL_BUILD"
		cmake --build . --target chcore.iso --parallel "$(nproc)"
	)

	[[ -f "$KERNEL_IMG" ]] || die "build did not produce $KERNEL_IMG"
	[[ -f "$KERNEL_ISO" ]] || die "build did not produce $KERNEL_ISO"
	cp -a "$KERNEL_ISO" "$ISO"
	[[ -f "$ISO" ]] || die "build did not produce $ISO"

	if rg -q 'tdx_early_debug_puts|\[ChCore probe\]' "$MAIN_C"; then
		die "main.c still contains early C diagnostics"
	fi
	if rg -q 'TDX_BOOT_PUTC|\[ASM0\]|\[ASM1\]|TDVMCALL_EXPOSE_REGS_MASK|^\s*ud2$|cofunc_after_asm0_ud2|cofunc_single_putc_ud2|MULTIBOOT_HEADER_TAG_CONSOLE_FLAGS' "$HEADER_S"; then
		die "header.S still contains early assembly diagnostics"
	fi
	if rg -q '\[GRUB probe\]|^set gfxpayload=text$' "$GRUB_CFG"; then
		die "grub.cfg still contains GRUB diagnostics"
	fi
	if LC_ALL=C grep -aFq "[ChCore probe]" "$ISO"; then
		die "rebuilt chcore.iso still contains ChCore diagnostics"
	fi
	if LC_ALL=C grep -aFq "[GRUB probe]" "$ISO"; then
		die "rebuilt chcore.iso still contains GRUB diagnostics"
	fi

	stat -c '%y %s %n' "$MAIN_C" "$HEADER_S" "$GRUB_CFG" "$MAIN_OBJ" "$HEADER_OBJ" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO" \
		| tee "$CLEANUP_BACKUP/stat.after-cleanup"
	sha256sum "$MAIN_C" "$HEADER_S" "$GRUB_CFG" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO" \
		| tee "$CLEANUP_BACKUP/sha256.after-cleanup"
	log "cleanup backup: $CLEANUP_BACKUP"
	log "clean ISO: $ISO"
}

main "$@"
