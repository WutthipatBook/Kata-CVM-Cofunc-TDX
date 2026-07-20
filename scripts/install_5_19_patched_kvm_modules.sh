#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
BUILD_DIR=${BUILD_DIR:-$ROOT/build/kernel-intel-tdx-5.19-cofunc}
REL=${REL:-5.19.0-cofunc-tdx-5.19+}
MODULE_ROOT=${MODULE_ROOT:-/lib/modules/$REL}
BACKUP_ROOT=${BACKUP_ROOT:-$ROOT/module-backups/kvm-5.19}

SRC_KVM=$BUILD_DIR/arch/x86/kvm/kvm.ko
SRC_KVM_INTEL=$BUILD_DIR/arch/x86/kvm/kvm-intel.ko

DST_DIR=$MODULE_ROOT/kernel/arch/x86/kvm
DST_KVM=$DST_DIR/kvm.ko.zst
DST_KVM_INTEL=$DST_DIR/kvm-intel.ko.zst
DST_KVM_RAW=$DST_DIR/kvm.ko
DST_KVM_INTEL_RAW=$DST_DIR/kvm-intel.ko

usage() {
	cat <<USAGE
Usage:
  $0 --check
  sudo $0 --install
  sudo $0 --reload
  sudo $0 --rollback BACKUP_DIR

--install backs up and replaces the compressed kvm.ko.zst and
kvm-intel.ko.zst files for $REL, then runs depmod. It does not reload KVM.

--reload refuses to proceed if /dev/kvm is busy, then reloads kvm_intel with
tdx=1. Use it only after coordinating with anyone else on this shared host.
USAGE
}

die() {
	echo "error: $*" >&2
	exit 1
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

require_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this mode with sudo/root"
}

require_running_kernel() {
	local running
	running=$(uname -r)
	[[ $running == "$REL" ]] || die "running kernel is $running, expected $REL"
}

module_release() {
	modinfo -F vermagic "$1" | awk '{ print $1 }'
}

hash_file() {
	sha256sum "$1" | awk '{ print $1 }'
}

hash_zst_payload() {
	zstdcat "$1" | sha256sum | awk '{ print $1 }'
}

check_inputs() {
	need_cmd awk
	need_cmd depmod
	need_cmd modinfo
	need_cmd sha256sum
	need_cmd zstd
	need_cmd zstdcat

	require_running_kernel
	need_dir "$BUILD_DIR"
	need_dir "$MODULE_ROOT"
	need_dir "$DST_DIR"
	need_file "$SRC_KVM"
	need_file "$SRC_KVM_INTEL"
	need_file "$DST_KVM"
	need_file "$DST_KVM_INTEL"

	[[ $(module_release "$SRC_KVM") == "$REL" ]] || die "$SRC_KVM has wrong vermagic"
	[[ $(module_release "$SRC_KVM_INTEL") == "$REL" ]] || die "$SRC_KVM_INTEL has wrong vermagic"

	echo "running kernel: $(uname -r)"
	echo "build dir: $BUILD_DIR"
	echo "module root: $MODULE_ROOT"
	echo "built kvm.ko sha256: $(hash_file "$SRC_KVM")"
	echo "built kvm-intel.ko sha256: $(hash_file "$SRC_KVM_INTEL")"
	echo "installed kvm.ko.zst payload sha256: $(hash_zst_payload "$DST_KVM")"
	echo "installed kvm-intel.ko.zst payload sha256: $(hash_zst_payload "$DST_KVM_INTEL")"

	if command -v fuser >/dev/null 2>&1 && fuser /dev/kvm >/dev/null 2>&1; then
		echo "/dev/kvm users are present:"
		fuser -v /dev/kvm || true
	else
		echo "/dev/kvm users: none detected"
	fi
}

backup_existing_modules() {
	local backup_dir
	backup_dir=$BACKUP_ROOT/$REL-$(date -u +%Y%m%d_%H%M%S)
	mkdir -p "$backup_dir/kernel/arch/x86/kvm"

	cp -a "$DST_KVM" "$backup_dir/kernel/arch/x86/kvm/"
	cp -a "$DST_KVM_INTEL" "$backup_dir/kernel/arch/x86/kvm/"
	[[ ! -e $DST_KVM_RAW ]] || cp -a "$DST_KVM_RAW" "$backup_dir/kernel/arch/x86/kvm/"
	[[ ! -e $DST_KVM_INTEL_RAW ]] || cp -a "$DST_KVM_INTEL_RAW" "$backup_dir/kernel/arch/x86/kvm/"

	{
		echo "running kernel: $(uname -r)"
		echo "build dir: $BUILD_DIR"
		echo "module root: $MODULE_ROOT"
		echo "old kvm.ko.zst sha256: $(hash_file "$DST_KVM")"
		echo "old kvm-intel.ko.zst sha256: $(hash_file "$DST_KVM_INTEL")"
		echo "old kvm.ko.zst payload sha256: $(hash_zst_payload "$DST_KVM")"
		echo "old kvm-intel.ko.zst payload sha256: $(hash_zst_payload "$DST_KVM_INTEL")"
		echo "new kvm.ko sha256: $(hash_file "$SRC_KVM")"
		echo "new kvm-intel.ko sha256: $(hash_file "$SRC_KVM_INTEL")"
	} >"$backup_dir/module-hashes.txt"

	printf '%s\n' "$backup_dir"
}

install_modules() {
	local backup_dir
	require_root
	check_inputs

	backup_dir=$(backup_existing_modules)

	zstd -q -f "$SRC_KVM" -o "$DST_KVM"
	zstd -q -f "$SRC_KVM_INTEL" -o "$DST_KVM_INTEL"
	rm -f "$DST_KVM_RAW" "$DST_KVM_INTEL_RAW"
	depmod "$REL"
	sync -f "$DST_KVM" 2>/dev/null || sync

	echo "backup_dir=$backup_dir"
	echo "installed kvm.ko.zst payload sha256: $(hash_zst_payload "$DST_KVM")"
	echo "installed kvm-intel.ko.zst payload sha256: $(hash_zst_payload "$DST_KVM_INTEL")"
	echo "installed modules; KVM is not reloaded yet"
}

require_no_kvm_users() {
	if command -v fuser >/dev/null 2>&1 && fuser /dev/kvm >/dev/null 2>&1; then
		fuser -v /dev/kvm >&2 || true
		die "/dev/kvm is busy; stop QEMU or other KVM users first"
	fi
}

reload_modules() {
	require_root
	require_running_kernel
	require_no_kvm_users

	modprobe -r kvm_intel
	modprobe -r kvm
	modprobe kvm
	modprobe kvm_intel tdx=1

	echo "loaded kvm_intel path: $(modinfo -n kvm_intel)"
	echo "loaded kvm srcversion: $(cat /sys/module/kvm/srcversion)"
	echo "loaded kvm_intel srcversion: $(cat /sys/module/kvm_intel/srcversion)"
	echo "kvm_intel tdx parameter: $(cat /sys/module/kvm_intel/parameters/tdx)"
}

rollback_modules() {
	local backup_dir=$1
	require_root
	require_running_kernel
	need_file "$backup_dir/kernel/arch/x86/kvm/kvm.ko.zst"
	need_file "$backup_dir/kernel/arch/x86/kvm/kvm-intel.ko.zst"

	cp -a "$backup_dir/kernel/arch/x86/kvm/kvm.ko.zst" "$DST_KVM"
	cp -a "$backup_dir/kernel/arch/x86/kvm/kvm-intel.ko.zst" "$DST_KVM_INTEL"
	if [[ -e $backup_dir/kernel/arch/x86/kvm/kvm.ko ]]; then
		cp -a "$backup_dir/kernel/arch/x86/kvm/kvm.ko" "$DST_KVM_RAW"
	else
		rm -f "$DST_KVM_RAW"
	fi
	if [[ -e $backup_dir/kernel/arch/x86/kvm/kvm-intel.ko ]]; then
		cp -a "$backup_dir/kernel/arch/x86/kvm/kvm-intel.ko" "$DST_KVM_INTEL_RAW"
	else
		rm -f "$DST_KVM_INTEL_RAW"
	fi
	depmod "$REL"

	echo "rolled back module files from: $backup_dir"
	echo "KVM is not reloaded yet; run --reload after coordination if needed"
}

case "${1:-}" in
	--check)
		check_inputs
		;;
	--install)
		install_modules
		;;
	--reload)
		reload_modules
		;;
	--rollback)
		[[ $# -eq 2 ]] || die "usage: $0 --rollback BACKUP_DIR"
		rollback_modules "$2"
		;;
	-h|--help|"")
		usage
		;;
	*)
		usage
		die "unknown argument: $1"
		;;
esac
