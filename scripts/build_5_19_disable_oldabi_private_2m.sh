#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
SRC=${SRC:-$ROOT/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot}
BUILD_DIR=${BUILD_DIR:-$ROOT/build/kernel-intel-tdx-5.19-cofunc}
PATCH_FILE=${PATCH_FILE:-$BUNDLE/patches/host-kernel/0017-Diagnostic-disable-oldabi-private-2m-promotion.patch}
JOBS=${JOBS:-16}
STAMP=$(date -u +%Y%m%d_%H%M%S)
BACKUP_DIR=${BACKUP_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/host-kernel-disable-oldabi-private-2m-$STAMP}
MARKER='CoFunc old-ABI private 2M promotion disabled diagnostic'
OLDABI_2M_MARKER='CoFunc old-ABI private 2M promotion'
OLDABI_RELEASE_MARKER='CoFunc old-ABI (private|normal-slot) fault release page-flag cleanup diagnostic'
TDX_UNPIN_MARKER='CoFunc old-ABI TDX unpin page-flag cleanup diagnostic'
TDP_AD_MARKER='CoFunc old-ABI (private|normal-slot) TDP SPTE A/D suppress'

usage() {
	cat <<USAGE
Usage:
  $0 --check
  sudo $0 --apply-build
  sudo $0 --reverse-build

--apply-build applies the diagnostic that disables old-ABI private 2M
promotion while leaving the current page-release cleanup and private TDP SPTE
A/D suppression intact, then rebuilds arch/x86/kvm.

--reverse-build reverses only this no-2M diagnostic and rebuilds arch/x86/kvm.
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
	need_file "$PATCH_FILE"
}

patch_state() {
	if rg -q "$MARKER" "$SRC/arch/x86/kvm/mmu/mmu.c"; then
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

oldabi_release_state() {
	if rg -q "$OLDABI_RELEASE_MARKER" "$SRC/arch/x86/kvm/mmu/mmu.c"; then
		echo "applied"
	else
		echo "not-applied"
	fi
}

tdx_unpin_state() {
	if rg -q "$TDX_UNPIN_MARKER" "$SRC/arch/x86/kvm/vmx/tdx.c"; then
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

check_state() {
	check_inputs
	echo "source: $SRC"
	echo "build dir: $BUILD_DIR"
	echo "patch: $PATCH_FILE"
	echo "patch sha256: $(sha256sum "$PATCH_FILE" | awk '{ print $1 }')"
	echo "0017 no-2M diagnostic state: $(patch_state)"
	echo "0016 private-TDP-SPTE A/D suppression state: $(tdp_ad_state)"
	echo "0015 private-fault release flag-cleanup state: $(oldabi_release_state)"
	echo "0014 TDX unpin flag-cleanup state: $(tdx_unpin_state)"
	echo "0013 old-ABI private 2M promotion state: $(oldabi_2m_state)"
	echo "mount: $(findmnt -no OPTIONS /mnt/new_disk 2>/dev/null || true)"
}

apply_patch_file() {
	check_inputs
	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$SRC/arch/x86/kvm/mmu/mmu.c" "$BACKUP_DIR/mmu.c.before"
	sha256sum "$SRC/arch/x86/kvm/mmu/mmu.c" >"$BACKUP_DIR/source.before.sha256"
	sha256sum "$PATCH_FILE" >"$BACKUP_DIR/patch.sha256"

	if [[ $(patch_state) == applied ]]; then
		die "0017 diagnostic already appears applied"
	fi
	if [[ $(oldabi_2m_state) != applied ]]; then
		die "0013 old-ABI private 2M promotion must be present before disabling it"
	fi
	if [[ $(oldabi_release_state) != applied ]]; then
		die "0015 private-fault release diagnostic must be applied for this A/B"
	fi
	if [[ $(tdx_unpin_state) != applied ]]; then
		die "0014 TDX unpin diagnostic must be applied for this A/B"
	fi
	if [[ $(tdp_ad_state) != applied ]]; then
		die "private-TDP-SPTE A/D suppression must remain applied for this A/B"
	fi

	log "applying no-2M old-ABI private mapping diagnostic"
	as_tree_owner patch -d "$SRC" -p1 -i "$PATCH_FILE"
	rg -n "$MARKER|cofunc_tdx_oldabi_private_2m_capable|cofunc_tdx_oldabi_private_2m_disabled_log_budget|CoFunc old-ABI private 2M promotion" \
		"$SRC/arch/x86/kvm/mmu/mmu.c" >"$BACKUP_DIR/source.after.rg"
	sha256sum "$SRC/arch/x86/kvm/mmu/mmu.c" >"$BACKUP_DIR/source.after.sha256"
	log "patch evidence: $BACKUP_DIR"
}

reverse_patch_file() {
	check_inputs
	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$SRC/arch/x86/kvm/mmu/mmu.c" "$BACKUP_DIR/mmu.c.before-reverse"
	sha256sum "$SRC/arch/x86/kvm/mmu/mmu.c" >"$BACKUP_DIR/source.before-reverse.sha256"

	if [[ $(patch_state) != applied ]]; then
		die "0017 diagnostic does not appear applied"
	fi

	log "reversing no-2M old-ABI private mapping diagnostic"
	as_tree_owner patch -R -d "$SRC" -p1 -i "$PATCH_FILE"
	sha256sum "$SRC/arch/x86/kvm/mmu/mmu.c" >"$BACKUP_DIR/source.after-reverse.sha256"
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
