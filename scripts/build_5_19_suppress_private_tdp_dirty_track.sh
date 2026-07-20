#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
SRC=${SRC:-$ROOT/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot}
BUILD_DIR=${BUILD_DIR:-$ROOT/build/kernel-intel-tdx-5.19-cofunc}
PATCH_FILE=${PATCH_FILE:-$BUNDLE/patches/host-kernel/0018-Diagnostic-suppress-private-tdp-spte-dirty-track.patch}
JOBS=${JOBS:-16}
STAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_DIR=${BACKUP_DIR:-$BUNDLE/backups/host-kernel-suppress-private-tdp-dirty-track-$STAMP}
MARKER='CoFunc old-ABI private TDP SPTE dirty suppress'
TDP_AD_MARKER='CoFunc old-ABI private TDP SPTE A/D suppress'
OLDABI_2M_MARKER='CoFunc old-ABI private 2M promotion'
NO2M_MARKER='CoFunc old-ABI private 2M promotion disabled diagnostic'

usage() {
	cat <<USAGE
Usage:
  $0 --check
  sudo $0 --apply-build
  sudo $0 --reverse-build

--apply-build applies the diagnostic that suppresses generic dirty page-flag
tracking for private TDP SPTE changes, then rebuilds arch/x86/kvm.

--reverse-build reverses only this diagnostic and rebuilds arch/x86/kvm.
It does not install or reload modules.
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
	owner=$(stat -c %U "$SRC/arch/x86/kvm/mmu/tdp_mmu.c")
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
	need_file "$SRC/arch/x86/kvm/mmu/tdp_mmu.c"
	need_file "$PATCH_FILE"
}

patch_state() {
	if rg -q "$MARKER" "$SRC/arch/x86/kvm/mmu/tdp_mmu.c"; then
		echo "applied"
	else
		echo "not-applied"
	fi
}

tdp_ad_state() {
	if rg -q "$TDP_AD_MARKER" "$SRC/arch/x86/kvm/mmu/tdp_mmu.c"; then
		echo "applied"
	else
		echo "not-applied"
	fi
}

oldabi_2m_state() {
	if rg -q "$OLDABI_2M_MARKER" "$SRC/arch/x86/kvm/mmu/mmu.c"; then
		echo "applied"
	else
		echo "not-applied"
	fi
}

no2m_state() {
	if rg -q "$NO2M_MARKER" "$SRC/arch/x86/kvm/mmu/mmu.c"; then
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
	echo "0018 private-TDP-SPTE dirty suppression state: $(patch_state)"
	echo "0016 private-TDP-SPTE A/D suppression state: $(tdp_ad_state)"
	echo "0017 no-2M diagnostic state: $(no2m_state)"
	echo "0013 old-ABI private 2M promotion state: $(oldabi_2m_state)"
	echo "mount: $(findmnt -no OPTIONS /mnt/new_disk 2>/dev/null || true)"
}

apply_patch_file() {
	check_inputs
	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$SRC/arch/x86/kvm/mmu/tdp_mmu.c" "$BACKUP_DIR/tdp_mmu.c.before"
	sha256sum "$SRC/arch/x86/kvm/mmu/tdp_mmu.c" >"$BACKUP_DIR/source.before.sha256"
	sha256sum "$PATCH_FILE" >"$BACKUP_DIR/patch.sha256"

	if [[ $(patch_state) == applied ]]; then
		die "0018 diagnostic already appears applied"
	fi
	if [[ $(tdp_ad_state) != applied ]]; then
		die "0016 private-TDP-SPTE A/D suppression must be applied before 0018"
	fi
	if [[ $(oldabi_2m_state) != applied ]]; then
		die "0013 old-ABI private 2M promotion must be applied before this A/B"
	fi
	if [[ $(no2m_state) == applied ]]; then
		die "0017 no-2M diagnostic is still applied; reverse it before this A/B"
	fi

	log "applying private-TDP-SPTE dirty suppression diagnostic"
	as_tree_owner patch -d "$SRC" -p1 -i "$PATCH_FILE"
	rg -n "$MARKER|cofunc_tdx_private_spte_skip_dirty_track|kvm_set_pfn_dirty|cofunc_tdx_private_spte_skip_ad_track" \
		"$SRC/arch/x86/kvm/mmu/tdp_mmu.c" >"$BACKUP_DIR/source.after.rg"
	sha256sum "$SRC/arch/x86/kvm/mmu/tdp_mmu.c" >"$BACKUP_DIR/source.after.sha256"
	log "patch evidence: $BACKUP_DIR"
}

reverse_patch_file() {
	check_inputs
	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$SRC/arch/x86/kvm/mmu/tdp_mmu.c" "$BACKUP_DIR/tdp_mmu.c.before-reverse"
	sha256sum "$SRC/arch/x86/kvm/mmu/tdp_mmu.c" >"$BACKUP_DIR/source.before-reverse.sha256"

	if [[ $(patch_state) != applied ]]; then
		die "0018 diagnostic does not appear applied"
	fi

	log "reversing private-TDP-SPTE dirty suppression diagnostic"
	as_tree_owner patch -R -d "$SRC" -p1 -i "$PATCH_FILE"
	sha256sum "$SRC/arch/x86/kvm/mmu/tdp_mmu.c" >"$BACKUP_DIR/source.after-reverse.sha256"
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
