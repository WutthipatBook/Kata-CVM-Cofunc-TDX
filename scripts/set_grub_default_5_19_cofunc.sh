#!/usr/bin/env bash
set -Eeuo pipefail

REL="5.19.0-cofunc-tdx-5.19+"
OLD_ENTRY="gnulinux-advanced-c09b0899-4a52-4d88-92f9-03deb85598da>gnulinux-6.19.0-rc6-cofunc-tdx+-advanced-c09b0899-4a52-4d88-92f9-03deb85598da"
NEW_ENTRY="gnulinux-advanced-c09b0899-4a52-4d88-92f9-03deb85598da>gnulinux-5.19.0-cofunc-tdx-5.19+-advanced-c09b0899-4a52-4d88-92f9-03deb85598da"
GRUB_DEFAULT_FILE="/etc/default/grub"
BACKUP_ROOT="/mnt/new_disk/cofunc_tdx_artifact/boot-backups"

die() {
	echo "error: $*" >&2
	exit 1
}

require_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo/root"
}

mode=${1:-}
case "$mode" in
	--set-5.19|--restore-6.19|--check) ;;
	-h|--help|"")
		cat <<USAGE
Usage:
  sudo $0 --set-5.19
  sudo $0 --restore-6.19
  $0 --check
USAGE
		exit 0
		;;
	*)
		die "unknown mode: $mode"
		;;
esac

if [[ $mode == "--check" ]]; then
	echo "running kernel: $(uname -r)"
	echo "configured GRUB_DEFAULT:"
	sed -n 's/^GRUB_DEFAULT=//p' "$GRUB_DEFAULT_FILE"
	echo "grub.cfg default line:"
	sed -n 's/^[[:space:]]*set default="\([^"]*gnulinux-[^"]*\)"/"\1"/p' /boot/grub/grub.cfg | head -1
	exit 0
fi

require_root
[[ -f /boot/vmlinuz-$REL ]] || die "missing /boot/vmlinuz-$REL"
[[ -f /boot/initrd.img-$REL ]] || die "missing /boot/initrd.img-$REL"
grep -Fq "$NEW_ENTRY" /boot/grub/grub.cfg || die "5.19 GRUB entry not present in /boot/grub/grub.cfg"
grep -Fq "$OLD_ENTRY" /boot/grub/grub.cfg || die "6.19 GRUB entry not present in /boot/grub/grub.cfg"

stamp=$(date -u +%Y%m%d_%H%M%S)
backup_dir="$BACKUP_ROOT/grub-default-switch-$stamp"
mkdir -p "$backup_dir"
cp -a "$GRUB_DEFAULT_FILE" "$backup_dir/default-grub.before"
cp -a /boot/grub/grub.cfg "$backup_dir/grub.cfg.before"
grub-editenv list >"$backup_dir/grub-editenv.before" 2>/dev/null || true
uname -a >"$backup_dir/uname.before"

target=$NEW_ENTRY
label=$REL
if [[ $mode == "--restore-6.19" ]]; then
	target=$OLD_ENTRY
	label="6.19.0-rc6-cofunc-tdx+"
fi

tmp=$(mktemp)
awk -v target="$target" '
	BEGIN { changed = 0 }
	/^GRUB_DEFAULT=/ {
		print "GRUB_DEFAULT=\"" target "\""
		changed = 1
		next
	}
	{ print }
	END {
		if (!changed)
			print "GRUB_DEFAULT=\"" target "\""
	}
' "$GRUB_DEFAULT_FILE" >"$tmp"
install -m 0644 "$tmp" "$GRUB_DEFAULT_FILE"
rm -f "$tmp"

update-grub

cp -a "$GRUB_DEFAULT_FILE" "$backup_dir/default-grub.after"
cp -a /boot/grub/grub.cfg "$backup_dir/grub.cfg.after"
grub-editenv list >"$backup_dir/grub-editenv.after" 2>/dev/null || true
sed -n 's/^GRUB_DEFAULT=//p' "$GRUB_DEFAULT_FILE" >"$backup_dir/grub-default.after"
sed -n 's/^[[:space:]]*set default="\([^"]*gnulinux-[^"]*\)"/"\1"/p' /boot/grub/grub.cfg | head -1 >"$backup_dir/grub-cfg-default.after"

echo "Configured persistent GRUB default for: $label"
echo "Backup directory: $backup_dir"
echo "Current /etc/default/grub GRUB_DEFAULT:"
sed -n 's/^GRUB_DEFAULT=//p' "$GRUB_DEFAULT_FILE"
echo "Current /boot/grub/grub.cfg default:"
sed -n 's/^[[:space:]]*set default="\([^"]*gnulinux-[^"]*\)"/"\1"/p' /boot/grub/grub.cfg | head -1
echo
echo "Rollback command:"
echo "  sudo $0 --restore-6.19"
