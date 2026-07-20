#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
ARTIFACT="$ROOT/cofunc-artifact-oldabi"
PATCH_FILE="$BUNDLE/patches/cofunc-artifact-oldabi/0001-Skip-TDX-MISC-ENABLE-wrmsr-diagnostic.patch"
RUNNER="$BUNDLE/scripts/run_oldabi_5_19_fig11.sh"
TDX_C="$ARTIFACT/cvm_os/kernel/arch/x86_64/plat/intel_tdx/tdx.c"
ISO="$ARTIFACT/cvm_os/build/chcore.iso"
KERNEL_BUILD="$ARTIFACT/cvm_os/build/kernel"
KERNEL_IMG="$KERNEL_BUILD/kernel.img"
KERNEL_ISO="$KERNEL_BUILD/arch/x86_64/boot/intel_tdx/chcore.iso"
TDX_OBJ="$KERNEL_BUILD/CMakeFiles/kernel.img.dir/arch/x86_64/plat/intel_tdx/tdx.c.obj"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BUNDLE/backups/oldabi-turbo-msr-skip-$STAMP"
OUT="${OUT:-$ROOT/results/oldabi_5_19_turbo_msr_skip_smoke_$STAMP}"
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
	for path in "$TDX_C" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO"; do
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
		[[ -f "$BACKUP_DIR/kernel.img.before" ]] && cp -a "$BACKUP_DIR/kernel.img.before" "$KERNEL_IMG"
		if [[ -f "$BACKUP_DIR/kernel-chcore.iso.before" ]]; then
			cp -a "$BACKUP_DIR/kernel-chcore.iso.before" "$KERNEL_ISO"
		else
			rm -f "$KERNEL_ISO"
		fi
		[[ -f "$BACKUP_DIR/chcore.iso.before" ]] && cp -a "$BACKUP_DIR/chcore.iso.before" "$ISO"
		rm -f "$TDX_OBJ"
		hash_state >"$BACKUP_DIR/sha256.restored"
		if rg -q 'CoFunc diag|skip TDX WRMSR|TDX WRMSR failed' "$TDX_C"; then
			log "warning: diagnostic marker still present in $TDX_C"
		fi
		log "restore evidence: $BACKUP_DIR"
	fi
	exit "$rc"
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -d "$ARTIFACT/cvm_os" ]] || die "missing artifact CVM OS: $ARTIFACT/cvm_os"
	[[ -f "$PATCH_FILE" ]] || die "missing patch: $PATCH_FILE"
	[[ -x "$RUNNER" ]] || die "missing old-ABI runner: $RUNNER"
	[[ -f "$TDX_C" ]] || die "missing TDX source: $TDX_C"
	[[ -d "$KERNEL_BUILD" ]] || die "missing kernel build dir: $KERNEL_BUILD"
	[[ -f "$KERNEL_IMG" ]] || die "missing kernel image: $KERNEL_IMG"
	[[ -f "$ISO" ]] || die "missing runtime ISO: $ISO"

	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$TDX_C" "$BACKUP_DIR/tdx.c.before"
	cp -a "$KERNEL_IMG" "$BACKUP_DIR/kernel.img.before"
	[[ -f "$KERNEL_ISO" ]] && cp -a "$KERNEL_ISO" "$BACKUP_DIR/kernel-chcore.iso.before"
	cp -a "$ISO" "$BACKUP_DIR/chcore.iso.before"
	hash_state >"$BACKUP_DIR/sha256.before"
	backup_done=1
	trap cleanup EXIT

	if rg -q 'CoFunc diag|skip TDX WRMSR|TDX WRMSR failed' "$TDX_C"; then
		die "diagnostic marker is already present in $TDX_C; refusing to stack patches"
	fi

	log "applying old-ABI TDX WRMSR diagnostic patch"
	patch -d "$ARTIFACT" -p1 -i "$PATCH_FILE"

	log "removing stale old-ABI TDX build outputs"
	rm -f "$TDX_OBJ" "$KERNEL_IMG" "$KERNEL_ISO" "$ISO"

	log "building old-ABI ChCore ISO with diagnostic WRMSR skip"
	(
		cd "$KERNEL_BUILD"
		cmake --build . --target chcore.iso --parallel "$(nproc)"
	)

	[[ -f "$KERNEL_IMG" ]] || die "build did not produce $KERNEL_IMG"
	[[ -f "$KERNEL_ISO" || -f "$ISO" ]] || die "build produced neither $KERNEL_ISO nor $ISO"
	[[ -f "$KERNEL_ISO" ]] && cp -a "$KERNEL_ISO" "$ISO"
	[[ -f "$ISO" ]] || die "build did not produce $ISO"

	LC_ALL=C grep -aFq "[CoFunc diag] skip TDX WRMSR 0x1a0" "$KERNEL_IMG" \
		|| die "rebuilt kernel.img does not contain diagnostic skip marker"
	LC_ALL=C grep -aFq "[CoFunc diag] skip TDX WRMSR 0x1a0" "$ISO" \
		|| die "rebuilt chcore.iso does not contain diagnostic skip marker"
	hash_state >"$BACKUP_DIR/sha256.diagnostic"
	cp -a "$KERNEL_IMG" "$BACKUP_DIR/kernel.img.diagnostic"
	[[ -f "$KERNEL_ISO" ]] && cp -a "$KERNEL_ISO" "$BACKUP_DIR/kernel-chcore.iso.diagnostic"
	cp -a "$ISO" "$BACKUP_DIR/chcore.iso.diagnostic"

	log "running old-ABI smoke with diagnostic ISO: $OUT"
	STOP_AFTER_SMOKE=1 OUT="$OUT" "$RUNNER"
	log "diagnostic smoke completed: $OUT"
}

main "$@"
