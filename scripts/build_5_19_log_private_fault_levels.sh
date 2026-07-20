#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
SRC=${SRC:-$ROOT/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot}
BUILD_DIR=${BUILD_DIR:-$ROOT/build/kernel-intel-tdx-5.19-cofunc}
PATCH_FILE=${PATCH_FILE:-$BUNDLE/patches/host-kernel/0007-Diagnostic-log-private-fault-levels.patch}
JOBS=${JOBS:-16}
STAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_DIR=${BACKUP_DIR:-$BUNDLE/backups/host-kernel-log-private-fault-levels-$STAMP}
MARKER='CoFunc old-ABI private fault level diagnostic'
CONFLICT_0006_MARKER='CoFunc old-ABI private PFN flag cleanup diagnostic'
LEGACY_AD_MARKER='CoFunc old-ABI A/D diagnostic'
LEGACY_ACCESSED_MARKER='Diagnostic for old-ABI TDX bad-page reports'

usage() {
	cat <<USAGE
Usage:
  $0 --check
  sudo $0 --apply-build
  sudo $0 --reverse-build

--apply-build remounts /mnt/new_disk read-write if needed, applies the private
fault level diagnostic patch to the 5.19 source tree, and rebuilds arch/x86/kvm.

--reverse-build reverses only this diagnostic patch and rebuilds arch/x86/kvm.
It does not install or reload modules; use install_5_19_patched_kvm_modules.sh
for that.
USAGE
}

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

need_file() {
	[[ -f $1 ]] || die "missing required file: $1"
}

need_dir() {
	[[ -d $1 ]] || die "missing required directory: $1"
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

ensure_rw() {
	findmnt /mnt/new_disk >/dev/null || die "/mnt/new_disk is not mounted"
	local opts
	opts=$(findmnt -no OPTIONS /mnt/new_disk)
	if [[ ,$opts, == *,ro,* ]]; then
		[[ ${EUID:-$(id -u)} -eq 0 ]] || die "/mnt/new_disk is read-only; rerun with sudo"
		log "remounting /mnt/new_disk read-write"
		mount -o remount,rw /mnt/new_disk
	fi
	opts=$(findmnt -no OPTIONS /mnt/new_disk)
	[[ ,$opts, == *,rw,* ]] || die "/mnt/new_disk is not read-write: $opts"
}

as_tree_owner() {
	local owner
	owner=$(stat -c %U "$SRC/arch/x86/kvm/mmu/mmu.c")
	if [[ ${EUID:-$(id -u)} -eq 0 && $owner != root && -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
		sudo -u "$SUDO_USER" env PATH="$PATH" "$@"
	else
		"$@"
	fi
}

check_inputs() {
	need_cmd findmnt
	need_cmd make
	need_cmd patch
	need_cmd rg
	need_cmd sha256sum
	need_dir "$SRC"
	need_dir "$BUILD_DIR"
	need_file "$SRC/arch/x86/kvm/mmu/mmu.c"
	need_file "$SRC/arch/x86/kvm/vmx/tdx.c"
	need_file "$SRC/include/linux/kvm_host.h"
	need_file "$SRC/virt/kvm/kvm_main.c"
	need_file "$PATCH_FILE"
}

patch_state() {
	if rg -q "$MARKER" "$SRC/arch/x86/kvm/mmu/mmu.c" "$SRC/arch/x86/kvm/vmx/tdx.c"; then
		echo "applied"
	else
		echo "not-applied"
	fi
}

conflict_0006_state() {
	if rg -q "$CONFLICT_0006_MARKER" "$SRC/include/linux/kvm_host.h" "$SRC/arch/x86/kvm/vmx/tdx.c"; then
		echo "applied"
	else
		echo "not-applied"
	fi
}

legacy_ad_state() {
	if rg -q "$LEGACY_AD_MARKER" "$SRC/virt/kvm/kvm_main.c"; then
		echo "applied"
	else
		echo "not-applied"
	fi
}

legacy_accessed_state() {
	if rg -q "$LEGACY_ACCESSED_MARKER" "$SRC/virt/kvm/kvm_main.c"; then
		echo "applied"
	else
		echo "not-applied"
	fi
}

check_state() {
	check_inputs
	echo "source: $SRC"
	echo "build dir: $BUILD_DIR"
	echo "patch: $PATCH_FILE"
	echo "patch sha256: $(sha256sum "$PATCH_FILE" | awk '{ print $1 }')"
	echo "state: $(patch_state)"
	echo "0006 flag-cleanup state: $(conflict_0006_state)"
	echo "legacy 0005 skip-dirty/accessed state: $(legacy_ad_state)"
	echo "legacy 0004 skip-accessed state: $(legacy_accessed_state)"
	echo "mount: $(findmnt -no OPTIONS /mnt/new_disk 2>/dev/null || true)"
}

apply_patch_file() {
	check_inputs
	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$SRC/arch/x86/kvm/mmu/mmu.c" "$BACKUP_DIR/mmu.c.before"
	cp -a "$SRC/arch/x86/kvm/vmx/tdx.c" "$BACKUP_DIR/tdx.c.before"
	sha256sum "$SRC/arch/x86/kvm/mmu/mmu.c" \
		"$SRC/arch/x86/kvm/vmx/tdx.c" >"$BACKUP_DIR/source.before.sha256"
	sha256sum "$PATCH_FILE" >"$BACKUP_DIR/patch.sha256"

	if [[ $(patch_state) == applied ]]; then
		die "patch already appears applied"
	fi
	if [[ $(conflict_0006_state) == applied ]]; then
		die "0006 flag-cleanup diagnostic appears applied; reverse it before applying this diagnostic"
	fi
	if [[ $(legacy_ad_state) == applied ]]; then
		die "legacy 0005 skip-dirty/accessed diagnostic appears applied; reverse it before applying this diagnostic"
	fi
	if [[ $(legacy_accessed_state) == applied ]]; then
		die "legacy 0004 skip-accessed diagnostic appears applied; reverse it before applying this diagnostic"
	fi

	log "applying private fault level diagnostic patch"
	as_tree_owner patch -d "$SRC" -p1 -i "$PATCH_FILE"
	rg -n "$MARKER|private_pfn|hugepage_adjust|direct_map|set_private_spte" \
		"$SRC/arch/x86/kvm/mmu/mmu.c" \
		"$SRC/arch/x86/kvm/vmx/tdx.c" >"$BACKUP_DIR/source.after.rg"
	sha256sum "$SRC/arch/x86/kvm/mmu/mmu.c" \
		"$SRC/arch/x86/kvm/vmx/tdx.c" >"$BACKUP_DIR/source.after.sha256"
	log "patch evidence: $BACKUP_DIR"
}

reverse_patch_file() {
	check_inputs
	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$SRC/arch/x86/kvm/mmu/mmu.c" "$BACKUP_DIR/mmu.c.before-reverse"
	cp -a "$SRC/arch/x86/kvm/vmx/tdx.c" "$BACKUP_DIR/tdx.c.before-reverse"
	sha256sum "$SRC/arch/x86/kvm/mmu/mmu.c" \
		"$SRC/arch/x86/kvm/vmx/tdx.c" >"$BACKUP_DIR/source.before-reverse.sha256"

	if [[ $(patch_state) != applied ]]; then
		die "patch does not appear applied"
	fi

	log "reversing private fault level diagnostic patch"
	as_tree_owner patch -R -d "$SRC" -p1 -i "$PATCH_FILE"
	sha256sum "$SRC/arch/x86/kvm/mmu/mmu.c" \
		"$SRC/arch/x86/kvm/vmx/tdx.c" >"$BACKUP_DIR/source.after-reverse.sha256"
	log "reverse evidence: $BACKUP_DIR"
}

build_modules() {
	check_inputs
	ensure_rw
	log "building KVM modules from $BUILD_DIR"
	as_tree_owner make -C "$BUILD_DIR" M=arch/x86/kvm -j"$JOBS" modules
	sha256sum "$BUILD_DIR/arch/x86/kvm/kvm.ko" \
		"$BUILD_DIR/arch/x86/kvm/kvm-intel.ko"
}

case "${1:-}" in
	--check)
		check_state
		;;
	--apply-build)
		apply_patch_file
		build_modules
		;;
	--reverse-build)
		reverse_patch_file
		build_modules
		;;
	-h|--help|"")
		usage
		;;
	*)
		usage
		die "unknown argument: $1"
		;;
esac
