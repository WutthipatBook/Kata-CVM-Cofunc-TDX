#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
SOURCE="${QEMU_SOURCE:-$ROOT/provenance/qemu-candidates/qemu-tdx-2022-09-01-v7.1}"
ORIGINAL_BUILD="${QEMU_ORIGINAL_BUILD:-$ROOT/build/qemu-tdx-2022-09-01-cofunc}"
BUILD="${QEMU_BUILD:-$ROOT/build/qemu-tdx-2022-09-01-cofunc-virtio9p}"
INSTALL="${QEMU_INSTALL:-$ROOT/install/qemu-tdx-2022-09-01-cofunc}"
QEMU="$INSTALL/bin/qemu-system-x86_64"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
BACKUP_DIR="${QEMU_BACKUP_DIR:-$ROOT/qemu-backups/oldabi-qemu7-$STAMP}"

die() {
	echo "error: $*" >&2
	exit 1
}

for command in meson ninja pkg-config; do
	command -v "$command" >/dev/null || die "missing command: $command"
done

missing=()
pkg-config --exists libattr || missing+=(libattr1-dev)
pkg-config --exists libcap-ng || missing+=(libcap-ng-dev)
if (( ${#missing[@]} )); then
	die "missing build dependencies: ${missing[*]}; install them with: sudo apt-get install ${missing[*]}"
fi

[[ -x "$SOURCE/configure" ]] || die "missing QEMU configure script: $SOURCE/configure"
[[ -x "$QEMU" ]] || die "missing installed QEMU: $QEMU"

if pgrep -f "$QEMU" >/dev/null; then
	die "old-ABI QEMU is currently running; stop the VM before rebuilding"
fi

if [[ -d "$ORIGINAL_BUILD/meson-private" ]]; then
	meson configure "$ORIGINAL_BUILD" -Dvirtfs=auto
fi

if [[ ! -f "$BUILD/build.ninja" ]]; then
	mkdir -p "$BUILD"
	(
		cd "$BUILD"
		"$SOURCE/configure" \
			--target-list=x86_64-softmmu \
			--prefix="$INSTALL" \
			--with-git-submodules=ignore \
			--enable-kvm \
			--disable-tcg \
			--disable-docs \
			--disable-gtk \
			--disable-sdl \
			--enable-fdt=system \
			--enable-slirp=system \
			--disable-vfio-user-server \
			--enable-virtfs
	)
else
	meson configure "$BUILD" -Dvirtfs=enabled
fi

ninja -C "$BUILD" qemu-system-x86_64

mkdir -p "$BACKUP_DIR"
cp -a "$QEMU" "$BACKUP_DIR/qemu-system-x86_64"
sha256sum "$BACKUP_DIR/qemu-system-x86_64" >"$BACKUP_DIR/SHA256SUMS.before"

ninja -C "$BUILD" install

if ! "$QEMU" -device help 2>&1 | grep -q 'virtio-9p-pci'; then
	die "rebuilt QEMU does not expose virtio-9p-pci"
fi

echo "backup_dir=$BACKUP_DIR"
echo "qemu=$QEMU"
sha256sum "$QEMU"
echo "virtio_9p=ready"
