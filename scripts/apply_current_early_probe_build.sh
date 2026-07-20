#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
ARTIFACT="$ROOT/cofunc-artifact"
PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0004-Early-TDX-main-entry-probe.patch"
OLDABI_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0005-Use-old-TDX-ABI-for-early-main-probe.patch"
ASM_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0006-Add-early-TDX-assembly-entry-probe.patch"
GRUB_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0007-Add-GRUB-handoff-probe.patch"
NOFB_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0008-Drop-Multiboot2-framebuffer-request.patch"
CONSOLE_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0009-Add-Multiboot2-console-flags-tag.patch"
GFXPAYLOAD_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0010-Set-GRUB-gfxpayload-text.patch"
ENTRY_TRAP_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0011-Add-early-entry-ud2-trap.patch"
AFTER_ASM0_TRAP_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0012-Add-after-ASM0-ud2-trap.patch"
SINGLE_PUTC_TRAP_PATCH_FILE="$BUNDLE/patches/cofunc-artifact/0013-Add-single-putc-ud2-trap.patch"
MAIN_C="$ARTIFACT/cvm_os/kernel/arch/x86_64/main.c"
HEADER_S="$ARTIFACT/cvm_os/kernel/arch/x86_64/boot/intel_tdx/init/header.S"
GRUB_CFG="$ARTIFACT/cvm_os/kernel/arch/x86_64/boot/intel_tdx/iso/boot/grub/grub.cfg"
ISO="$ARTIFACT/cvm_os/build/chcore.iso"
KERNEL_BUILD="$ARTIFACT/cvm_os/build/kernel"
KERNEL_IMG="$KERNEL_BUILD/kernel.img"
KERNEL_ISO="$KERNEL_BUILD/arch/x86_64/boot/intel_tdx/chcore.iso"
MAIN_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/arch/x86_64/main.c.obj"
HEADER_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/arch/x86_64/boot/intel_tdx/init/header.S.obj"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BUNDLE/backups/current-early-probe-$STAMP"

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
	[[ -d "$ARTIFACT/cvm_os" ]] || die "missing artifact CVM OS: $ARTIFACT/cvm_os"
	[[ -f "$PATCH_FILE" ]] || die "missing patch: $PATCH_FILE"
	[[ -f "$OLDABI_PATCH_FILE" ]] || die "missing patch: $OLDABI_PATCH_FILE"
	[[ -f "$ASM_PATCH_FILE" ]] || die "missing patch: $ASM_PATCH_FILE"
	[[ -f "$GRUB_PATCH_FILE" ]] || die "missing patch: $GRUB_PATCH_FILE"
	[[ -f "$NOFB_PATCH_FILE" ]] || die "missing patch: $NOFB_PATCH_FILE"
	[[ -f "$CONSOLE_PATCH_FILE" ]] || die "missing patch: $CONSOLE_PATCH_FILE"
		[[ -f "$GFXPAYLOAD_PATCH_FILE" ]] || die "missing patch: $GFXPAYLOAD_PATCH_FILE"
		[[ -f "$ENTRY_TRAP_PATCH_FILE" ]] || die "missing patch: $ENTRY_TRAP_PATCH_FILE"
		[[ -f "$AFTER_ASM0_TRAP_PATCH_FILE" ]] || die "missing patch: $AFTER_ASM0_TRAP_PATCH_FILE"
		[[ -f "$SINGLE_PUTC_TRAP_PATCH_FILE" ]] || die "missing patch: $SINGLE_PUTC_TRAP_PATCH_FILE"
	[[ -f "$MAIN_C" ]] || die "missing main.c: $MAIN_C"
	[[ -f "$HEADER_S" ]] || die "missing header.S: $HEADER_S"
	[[ -f "$GRUB_CFG" ]] || die "missing grub.cfg: $GRUB_CFG"
	[[ -d "$KERNEL_BUILD" ]] || die "missing kernel build dir: $KERNEL_BUILD"
		local trap_count=0
		[[ ${COFUNC_ENTRY_TRAP:-0} == 1 ]] && trap_count=$((trap_count + 1))
		[[ ${COFUNC_AFTER_ASM0_TRAP:-0} == 1 ]] && trap_count=$((trap_count + 1))
		[[ ${COFUNC_SINGLE_PUTC_TRAP:-0} == 1 ]] && trap_count=$((trap_count + 1))
		if ((trap_count > 1)); then
			die "set only one of COFUNC_ENTRY_TRAP=1, COFUNC_AFTER_ASM0_TRAP=1, or COFUNC_SINGLE_PUTC_TRAP=1"
		fi

	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$MAIN_C" "$BACKUP_DIR/main.c.before"
	cp -a "$HEADER_S" "$BACKUP_DIR/header.S.before"
	cp -a "$GRUB_CFG" "$BACKUP_DIR/grub.cfg.before"
	[[ -f "$ISO" ]] && cp -a "$ISO" "$BACKUP_DIR/chcore.iso.before"
	[[ -f "$KERNEL_IMG" ]] && cp -a "$KERNEL_IMG" "$BACKUP_DIR/kernel.img.before"
	[[ -f "$KERNEL_ISO" ]] && cp -a "$KERNEL_ISO" "$BACKUP_DIR/kernel-chcore.iso.before"
	sha256sum "$MAIN_C" "$HEADER_S" "$GRUB_CFG" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO" 2>/dev/null \
		| tee "$BACKUP_DIR/sha256.before"

	if rg -q 'tdx_early_debug_puts|\\[ChCore probe\\]' "$MAIN_C"; then
		log "early probe already present in $MAIN_C; not applying patch again"
	else
		log "applying early-main probe patch"
		patch -d "$ARTIFACT" -p1 -i "$PATCH_FILE"
	fi
	if rg -q 'TDX_HYPERCALL_STANDARD,' "$MAIN_C"; then
		log "early probe already uses old 5.19 TDX ABI"
	else
		log "switching early-main probe to old 5.19 TDX ABI"
		patch -d "$ARTIFACT" -p1 -i "$OLDABI_PATCH_FILE"
	fi
	if rg -q 'TDX_BOOT_PUTC|\\[ASM0\\]|TDVMCALL_EXPOSE_REGS_MASK' "$HEADER_S"; then
		log "early assembly entry probe already present"
	else
		log "applying early assembly entry probe"
		patch -d "$ARTIFACT" -p1 -i "$ASM_PATCH_FILE"
	fi
	if rg -q '\[GRUB probe\]' "$GRUB_CFG"; then
		log "GRUB handoff probe already present"
	else
		log "applying GRUB handoff probe"
		patch -d "$ARTIFACT" -p1 -i "$GRUB_PATCH_FILE"
	fi
	if rg -q 'MULTIBOOT_HEADER_TAG_FRAMEBUFFER' "$HEADER_S"; then
		log "dropping Multiboot2 framebuffer request"
		patch -d "$ARTIFACT" -p1 -i "$NOFB_PATCH_FILE"
	else
		log "Multiboot2 framebuffer request already absent"
	fi
	if rg -q 'MULTIBOOT_HEADER_TAG_CONSOLE_FLAGS' "$HEADER_S"; then
		log "Multiboot2 console flags tag already present"
	else
		log "adding Multiboot2 console flags tag"
		patch -d "$ARTIFACT" -p1 -i "$CONSOLE_PATCH_FILE"
	fi
	if rg -q '^set gfxpayload=text$' "$GRUB_CFG"; then
		log "GRUB gfxpayload=text already present"
	else
		log "forcing GRUB gfxpayload=text"
		patch -d "$ARTIFACT" -p1 -i "$GFXPAYLOAD_PATCH_FILE"
	fi
	if [[ ${COFUNC_ENTRY_TRAP:-0} == 1 ]]; then
		if rg -q '^\s*ud2$' "$HEADER_S"; then
			log "early entry UD2 trap already present"
		else
			log "adding early entry UD2 trap"
			patch -d "$ARTIFACT" -p1 -i "$ENTRY_TRAP_PATCH_FILE"
		fi
	else
		log "early entry UD2 trap disabled; set COFUNC_ENTRY_TRAP=1 to add it"
	fi
		if [[ ${COFUNC_AFTER_ASM0_TRAP:-0} == 1 ]]; then
			if rg -q 'cofunc_after_asm0_ud2' "$HEADER_S"; then
				log "after-ASM0 UD2 trap already present"
			else
				log "adding after-ASM0 UD2 trap"
			patch -d "$ARTIFACT" -p1 -i "$AFTER_ASM0_TRAP_PATCH_FILE"
		fi
		else
			log "after-ASM0 UD2 trap disabled; set COFUNC_AFTER_ASM0_TRAP=1 to add it"
		fi
		if [[ ${COFUNC_SINGLE_PUTC_TRAP:-0} == 1 ]]; then
			if rg -q 'cofunc_single_putc_ud2' "$HEADER_S"; then
				log "single-putc UD2 trap already present"
			else
				log "adding single-putc UD2 trap"
				patch -d "$ARTIFACT" -p1 -i "$SINGLE_PUTC_TRAP_PATCH_FILE"
			fi
		else
			log "single-putc UD2 trap disabled; set COFUNC_SINGLE_PUTC_TRAP=1 to add it"
		fi

	log "removing stale kernel outputs so the probe must be rebuilt"
	rm -f "$MAIN_OBJ" "$HEADER_OBJ" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO"

	log "building current ChCore kernel-subproject ISO with early probe"
	(
		cd "$KERNEL_BUILD"
		cmake --build . --target chcore.iso --parallel "$(nproc)"
	)

	[[ -f "$KERNEL_IMG" ]] || die "build did not produce $KERNEL_IMG"
	[[ -f "$KERNEL_ISO" ]] || die "build did not produce $KERNEL_ISO"
	cp -a "$KERNEL_ISO" "$ISO"
	[[ -f "$ISO" ]] || die "build did not produce $ISO"

	LC_ALL=C grep -aFq "[ChCore probe] main entry before uart_init" "$KERNEL_IMG" \
		|| die "rebuilt kernel.img does not contain early main-entry probe"
	LC_ALL=C grep -aFq "[ChCore probe] after uart_init" "$KERNEL_IMG" \
		|| die "rebuilt kernel.img does not contain after-uart probe"
	LC_ALL=C grep -aFq "[ChCore probe] main entry before uart_init" "$ISO" \
		|| die "rebuilt chcore.iso does not contain early main-entry probe"
	rg -q 'TDX_BOOT_PUTC|TDVMCALL_EXPOSE_REGS_MASK' "$HEADER_S" \
		|| die "header.S does not contain assembly entry probe"
	if rg -q 'MULTIBOOT_HEADER_TAG_FRAMEBUFFER' "$HEADER_S"; then
		die "header.S still contains Multiboot2 framebuffer request"
	fi
	rg -q 'MULTIBOOT_HEADER_TAG_CONSOLE_FLAGS' "$HEADER_S" \
		|| die "header.S does not contain Multiboot2 console flags tag"
	if [[ ${COFUNC_ENTRY_TRAP:-0} == 1 ]]; then
		rg -q '^\s*ud2$' "$HEADER_S" \
			|| die "header.S does not contain early entry UD2 trap"
	fi
		if [[ ${COFUNC_AFTER_ASM0_TRAP:-0} == 1 ]]; then
			rg -q 'cofunc_after_asm0_ud2' "$HEADER_S" \
				|| die "header.S does not contain after-ASM0 UD2 trap"
		fi
		if [[ ${COFUNC_SINGLE_PUTC_TRAP:-0} == 1 ]]; then
			rg -q 'cofunc_single_putc_ud2' "$HEADER_S" \
				|| die "header.S does not contain single-putc UD2 trap"
		fi
	rg -q '\[GRUB probe\] before multiboot2' "$GRUB_CFG" \
		|| die "grub.cfg does not contain GRUB handoff probe"
	rg -q '^set gfxpayload=text$' "$GRUB_CFG" \
		|| die "grub.cfg does not force gfxpayload=text"
	LC_ALL=C grep -aFq "[GRUB probe] before multiboot2" "$ISO" \
		|| die "rebuilt chcore.iso does not contain GRUB handoff probe"
	LC_ALL=C grep -aFq "[GRUB probe] gfxpayload=" "$ISO" \
		|| die "rebuilt chcore.iso does not contain GRUB gfxpayload probe"
	if [[ ${COFUNC_ENTRY_TRAP:-0} == 1 ]]; then
		LC_ALL=C objdump -d "$HEADER_OBJ" >"$BACKUP_DIR/header.S.obj.disasm"
		LC_ALL=C objdump -d "$KERNEL_IMG" >"$BACKUP_DIR/kernel.img.disasm"
		awk '/<_start>:/,/<_start64>:/' "$BACKUP_DIR/header.S.obj.disasm" >"$BACKUP_DIR/header.S.obj.start.disasm"
		awk '/<_start>:/,/<_start64>:/' "$BACKUP_DIR/kernel.img.disasm" >"$BACKUP_DIR/kernel.img.start.disasm"
		rg -q '\bud2\b' "$BACKUP_DIR/header.S.obj.start.disasm" \
			|| die "rebuilt header.S.obj does not contain early entry UD2 trap"
		rg -q '\bud2\b' "$BACKUP_DIR/kernel.img.start.disasm" \
			|| die "rebuilt kernel.img does not contain early entry UD2 trap"
	fi
		if [[ ${COFUNC_AFTER_ASM0_TRAP:-0} == 1 ]]; then
			LC_ALL=C objdump -d "$HEADER_OBJ" >"$BACKUP_DIR/header.S.obj.disasm"
			LC_ALL=C objdump -d "$KERNEL_IMG" >"$BACKUP_DIR/kernel.img.disasm"
			awk '/<_start>:/,/<_start64>:/' "$BACKUP_DIR/header.S.obj.disasm" >"$BACKUP_DIR/header.S.obj.start.disasm"
			awk '/<_start>:/,/<_start64>:/' "$BACKUP_DIR/kernel.img.disasm" >"$BACKUP_DIR/kernel.img.start.disasm"
		rg -q '\bud2\b' "$BACKUP_DIR/header.S.obj.start.disasm" \
			|| die "rebuilt header.S.obj does not contain after-ASM0 UD2 trap"
			rg -q '\bud2\b' "$BACKUP_DIR/kernel.img.start.disasm" \
				|| die "rebuilt kernel.img does not contain after-ASM0 UD2 trap"
		fi
		if [[ ${COFUNC_SINGLE_PUTC_TRAP:-0} == 1 ]]; then
			LC_ALL=C objdump -d "$HEADER_OBJ" >"$BACKUP_DIR/header.S.obj.disasm"
			LC_ALL=C objdump -d "$KERNEL_IMG" >"$BACKUP_DIR/kernel.img.disasm"
			awk '/<_start>:/,/<_start64>:/' "$BACKUP_DIR/header.S.obj.disasm" >"$BACKUP_DIR/header.S.obj.start.disasm"
			awk '/<_start>:/,/<_start64>:/' "$BACKUP_DIR/kernel.img.disasm" >"$BACKUP_DIR/kernel.img.start.disasm"
			rg -q '\bud2\b' "$BACKUP_DIR/header.S.obj.start.disasm" \
				|| die "rebuilt header.S.obj does not contain single-putc UD2 trap"
			rg -q '\bud2\b' "$BACKUP_DIR/kernel.img.start.disasm" \
				|| die "rebuilt kernel.img does not contain single-putc UD2 trap"
		fi

	stat -c '%y %s %n' "$MAIN_C" "$HEADER_S" "$GRUB_CFG" "$MAIN_OBJ" "$HEADER_OBJ" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO" \
		| tee "$BACKUP_DIR/stat.after"
	sha256sum "$MAIN_C" "$HEADER_S" "$GRUB_CFG" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO" \
		| tee "$BACKUP_DIR/sha256.after"
	log "backup: $BACKUP_DIR"
	log "built ISO: $ISO"
}

main "$@"
