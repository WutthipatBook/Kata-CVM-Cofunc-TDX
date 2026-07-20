#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/mnt/new_disk/cofunc_tdx_artifact"
SRC="$ROOT/provenance/kernel-candidates/tdx-kvm-2022.09.01-v5.19-snapshot"
BUILD="$ROOT/build/kernel-intel-tdx-5.19-cofunc"
REL="5.19.0-cofunc-tdx-5.19+"
STAGED_MODULES="$ROOT/install/kernel-5.19-modules-staging/lib/modules/$REL"
BACKUP_ROOT="$ROOT/boot-backups"

usage() {
	cat <<USAGE
Usage:
  $0 --check
  sudo $0 --install

Installs $REL as an additional kernel while keeping the current GRUB default.
It expects stripped modules to be staged at:
  $STAGED_MODULES
USAGE
}

die() {
	echo "error: $*" >&2
	exit 1
}

require_path() {
	[[ -e $1 ]] || die "missing required path: $1"
}

kernel_release_from_build() {
	make -s -C "$SRC" O="$BUILD" kernelrelease
}

current_grub_default() {
	local saved default_file
	saved=$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p' || true)
	if [[ -n ${saved:-} ]]; then
		printf '%s\n' "$saved"
		return
	fi
	default_file=$(sed -n 's/^GRUB_DEFAULT=//p' /etc/default/grub | head -1 | sed 's/^"//; s/"$//')
	printf '%s\n' "$default_file"
}

advanced_parent_id() {
	awk -F"'" '/^submenu .*Advanced options/ { print $4; exit }' /boot/grub/grub.cfg
}

entry_id_for_release() {
	local rel=$1
	awk -v rel="$rel" -F"'" '
		/^	menuentry / && index($0, "Linux " rel) && $0 !~ /recovery/ {
			print $4
			exit
		}
	' /boot/grub/grub.cfg
}

full_entry_for_release() {
	local rel=$1 parent child
	parent=$(advanced_parent_id)
	child=$(entry_id_for_release "$rel")
	[[ -n $parent ]] || return 1
	[[ -n $child ]] || return 1
	printf '%s>%s\n' "$parent" "$child"
}

check_inputs() {
	local actual_rel root_avail boot_avail staged_kb boot_need_kb

	require_path "$SRC/Makefile"
	require_path "$BUILD/arch/x86/boot/bzImage"
	require_path "$BUILD/System.map"
	require_path "$BUILD/.config"
	require_path "$STAGED_MODULES"
	require_path "$STAGED_MODULES/kernel/arch/x86/kvm/kvm.ko.zst"
	require_path "$STAGED_MODULES/kernel/arch/x86/kvm/kvm-intel.ko.zst"

	actual_rel=$(kernel_release_from_build)
	[[ $actual_rel == "$REL" ]] || die "build release is $actual_rel, expected $REL"

	root_avail=$(df -Pk / | awk 'NR == 2 { print $4 }')
	boot_avail=$(df -Pk /boot | awk 'NR == 2 { print $4 }')
	staged_kb=$(du -sk "$STAGED_MODULES" | awk '{ print $1 }')
	boot_need_kb=$((250 * 1024))

	# Root needs staged modules plus depmod metadata overhead.
	(( root_avail > staged_kb + 200 * 1024 )) || die "not enough free space on / for modules"
	# Boot needs kernel, System.map, config, and initramfs.
	(( boot_avail > boot_need_kb )) || die "not enough free space on /boot"

	echo "kernel release: $actual_rel"
	echo "staged modules: $(du -sh "$STAGED_MODULES" | awk '{ print $1 }')"
	echo "root free: $(df -h / | awk 'NR == 2 { print $4 }')"
	echo "boot free: $(df -h /boot | awk 'NR == 2 { print $4 }')"
	echo "current kernel: $(uname -r)"
	echo "current GRUB default: $(current_grub_default)"
}

install_kernel() {
	local backup_dir old_default parent child new_entry boot_once rollback_script

	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run install mode with sudo"
	check_inputs

	if [[ -e /lib/modules/$REL ]]; then
		die "/lib/modules/$REL already exists; remove it manually if you intend to reinstall"
	fi
	if [[ -e /boot/vmlinuz-$REL || -e /boot/initrd.img-$REL ]]; then
		die "/boot already contains files for $REL; remove them manually if you intend to reinstall"
	fi

	old_default=$(current_grub_default)
	backup_dir="$BACKUP_ROOT/$REL-$(date -u +%Y%m%d_%H%M%S)"
	mkdir -p "$backup_dir"

	cp -a /etc/default/grub "$backup_dir/default-grub"
	cp -a /boot/grub/grub.cfg "$backup_dir/grub.cfg"
	cp -a /boot/grub/grubenv "$backup_dir/grubenv"
	grub-editenv list >"$backup_dir/grub-editenv-list.txt" || true
	uname -a >"$backup_dir/uname-before.txt"
	df -h / /boot /mnt/new_disk >"$backup_dir/df-before.txt"

	echo "Installing stripped modules to /lib/modules/$REL"
	rsync -a --delete "$STAGED_MODULES/" "/lib/modules/$REL/"
	ln -sfn "$BUILD" "/lib/modules/$REL/build"
	ln -sfn "$SRC" "/lib/modules/$REL/source"

	echo "Installing kernel files to /boot"
	install -m 0644 "$BUILD/arch/x86/boot/bzImage" "/boot/vmlinuz-$REL"
	install -m 0644 "$BUILD/System.map" "/boot/System.map-$REL"
	install -m 0644 "$BUILD/.config" "/boot/config-$REL"

	echo "Running depmod and initramfs generation"
	depmod "$REL"
	update-initramfs -c -k "$REL"

	echo "Updating GRUB"
	update-grub

	if [[ -n $old_default && $old_default != "0" ]]; then
		grub-set-default "$old_default" || true
	fi

	parent=$(advanced_parent_id)
	child=$(entry_id_for_release "$REL")
	[[ -n $parent ]] || die "could not find advanced GRUB submenu after update-grub"
	[[ -n $child ]] || die "could not find GRUB menu entry for $REL after update-grub"
	new_entry="$parent>$child"

	boot_once="$ROOT/boot-5.19-once.sh"
	rollback_script="$ROOT/rollback-5.19-kernel.sh"

	cat >"$boot_once" <<EOF
#!/usr/bin/env bash
set -euo pipefail
sudo grub-reboot '$new_entry'
echo 'Next boot set to $REL once.'
echo 'Run: sudo reboot'
EOF
	chmod +x "$boot_once"

	cat >"$rollback_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ \${EUID:-\$(id -u)} -ne 0 ]]; then
	echo "Run with sudo: sudo \$0" >&2
	exit 1
fi
rm -rf '/lib/modules/$REL'
rm -f '/boot/vmlinuz-$REL' '/boot/System.map-$REL' '/boot/config-$REL' '/boot/initrd.img-$REL'
update-grub
grub-set-default '$old_default' || true
echo 'Removed $REL and restored saved GRUB default when possible.'
EOF
	chmod +x "$rollback_script"

	cat >"$backup_dir/install-summary.txt" <<EOF
Installed kernel: $REL
Previous running kernel: $(cat "$backup_dir/uname-before.txt")
Previous GRUB default: $old_default
New one-shot GRUB entry: $new_entry
Boot once helper: $boot_once
Rollback helper: $rollback_script
EOF

	df -h / /boot /mnt/new_disk >"$backup_dir/df-after.txt"

	echo
	echo "Installed $REL as an additional kernel."
	echo "Persistent GRUB default was left as:"
	echo "  $old_default"
	echo
	echo "To boot 5.19 exactly once:"
	echo "  sudo $boot_once"
	echo "  sudo reboot"
	echo
	echo "Rollback helper:"
	echo "  sudo $rollback_script"
	echo
	echo "Backup directory:"
	echo "  $backup_dir"
}

case "${1:-}" in
	--check)
		check_inputs
		;;
	--install)
		install_kernel
		;;
	-h|--help|"")
		usage
		;;
	*)
		usage
		die "unknown argument: $1"
		;;
esac
