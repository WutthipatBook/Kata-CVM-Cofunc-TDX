#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/mnt/new_disk/cofunc_tdx_artifact"
OLD_QEMU="$ROOT/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64"
OLD_QEMU_BIOS_DIR="$ROOT/install/qemu-tdx-2022-09-01-cofunc/share/qemu"
OVMF="${COFUNC_TDX_OVMF:-$ROOT/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd}"
REL="5.19.0-cofunc-tdx-5.19+"

TARGET="${TARGET:-current}"
LAUNCH_MODE="${LAUNCH_MODE:-artifact}"
QEMU_STRACE="${COFUNC_QEMU_STRACE:-0}"
QEMU_NO_REBOOT="${COFUNC_QEMU_NO_REBOOT:-1}"
QEMU_DEBUG="${COFUNC_QEMU_DEBUG:-0}"
TDX_SMP="${COFUNC_TDX_SMP:-16}"
BOOT_TIMEOUT="${COFUNC_CVM_BOOT_TIMEOUT:-120}"
OUT="${OUT:-$ROOT/results/oldqemu_chcore_diag_$(date -u +%Y%m%d_%H%M%S)}"

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

ensure_mount_rw() {
	local opts
	findmnt /mnt/new_disk >/dev/null || die "/mnt/new_disk is not mounted"
	opts=$(findmnt -no OPTIONS /mnt/new_disk)
	if [[ ,$opts, == *,ro,* ]]; then
		log "remounting /mnt/new_disk read-write"
		mount -o remount,rw /mnt/new_disk
	fi
}

artifact_for_target() {
	case "$1" in
	current) printf '%s\n' "$ROOT/cofunc-artifact" ;;
	old) printf '%s\n' "$ROOT/cofunc-artifact-oldabi" ;;
	*) die "TARGET must be current, old, or both" ;;
	esac
}

cleanup_artifact() {
	local artifact=$1
	if [[ -x "$artifact/testcases/tools/cvm.sh" ]]; then
		COFUNC_CVM_USE_SUDO=0 "$artifact/testcases/tools/cvm.sh" clean >/dev/null 2>&1 || true
	fi
}

run_one() {
	local target=$1
	local artifact
	local log_file
	local trace_root
	local rc
	local iso
	local serial_file

	artifact=$(artifact_for_target "$target")
	[[ -x "$artifact/testcases/tools/cvm.sh" ]] || die "missing cvm.sh for $target: $artifact"
	[[ -f "$artifact/cvm_os/build/chcore.iso" ]] || die "missing chcore.iso for $target: $artifact"
	iso="$artifact/cvm_os/build/chcore.iso"

	log_file="$OUT/${target}-cvm.log"
	trace_root="$OUT/${target}-trace"
	mkdir -p "$trace_root"
	serial_file="$trace_root/${target}-serial.log"
	rc=0

	log "booting $target ChCore ISO with old QEMU mode=$LAUNCH_MODE"
	cleanup_artifact "$artifact"
	set +e
	case "$LAUNCH_MODE" in
	artifact)
		(
			cd "$artifact/testcases"
			export COFUNC_TDX_QEMU="$OLD_QEMU"
			export COFUNC_TDX_QEMU_BIOS_DIR="$OLD_QEMU_BIOS_DIR"
			export COFUNC_TDX_OVMF="$OVMF"
			export COFUNC_TDX_SMP="$TDX_SMP"
			export COFUNC_CVM_USE_SUDO=0
			export COFUNC_CVM_BOOT_TIMEOUT="$BOOT_TIMEOUT"
			export COFUNC_TRACE_ROOT="$trace_root"
			timeout --kill-after=30s "$((BOOT_TIMEOUT + 60))" "$artifact/testcases/tools/cvm.sh"
		) >"$log_file" 2>&1
		rc=$?
		;;
	artifact-fg)
		(
			cd "$artifact/cvm_os"
			qemu_cmd=(
				"$OLD_QEMU"
				-gdb tcp::0
				-L "$OLD_QEMU_BIOS_DIR"
				-accel kvm
				-cpu host
				-object tdx-guest,id=tdx0
				-machine q35,confidential-guest-support=tdx0,kernel-irqchip=split,smm=off
				-bios "$OVMF"
				-m 4G
				-smp "$TDX_SMP"
				-nodefaults
				-nographic
				-display none
				-monitor none
				-serial "file:$serial_file"
				-boot c
				-drive file=build/chcore.iso,if=none,id=bootdisk,format=raw,readonly=on
				-device virtio-blk-pci,drive=bootdisk,bootindex=1
			)
			if [[ "$QEMU_NO_REBOOT" == 1 ]]; then
				qemu_cmd+=(-no-reboot)
			fi
			if [[ "$QEMU_DEBUG" == 1 ]]; then
				qemu_cmd+=(-d guest_errors,int,cpu_reset -D "$trace_root/${target}-qemu-debug.log")
			fi
			printf 'timestamp=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			printf 'cwd=%s\n' "$PWD"
			printf 'strace=%s\n' "$QEMU_STRACE"
			printf 'no_reboot=%s\n' "$QEMU_NO_REBOOT"
			printf 'qemu_debug=%s\n' "$QEMU_DEBUG"
			printf 'command: %q' "$artifact/cvm_os/scripts/qemu/qemu_wrapper.sh"
			printf ' %q' "${qemu_cmd[@]}"
			printf '\n'
			set -x
			if [[ "$QEMU_STRACE" == 1 ]]; then
				timeout --kill-after=30s "$((BOOT_TIMEOUT + 60))" \
					strace -ff -tt -s 256 -o "$trace_root/${target}-qemu.strace" \
					"$artifact/cvm_os/scripts/qemu/qemu_wrapper.sh" "${qemu_cmd[@]}"
			else
				timeout --kill-after=30s "$((BOOT_TIMEOUT + 60))" \
					"$artifact/cvm_os/scripts/qemu/qemu_wrapper.sh" "${qemu_cmd[@]}"
			fi
		) >"$log_file" 2>&1
		rc=$?
		if grep -q "ChCore shell" "$log_file" "$serial_file" 2>/dev/null; then
			rc=0
		fi
		((rc == 0)) && rc=1
		;;
	direct)
		(
			set -x
			SLOT_ID=0 timeout --kill-after=30s "$((BOOT_TIMEOUT + 60))" \
				"$OLD_QEMU" \
				-gdb tcp::0 \
				-L "$OLD_QEMU_BIOS_DIR" \
				-m 4G \
				-smp "$TDX_SMP",sockets=1 \
				-cpu host,host-phys-bits,pmu=off,-intel-pt \
				-no-hpet \
				-nographic \
				-vga none \
				-nodefaults \
				-object tdx-guest,id=tdx0 \
				-machine q35,accel=kvm,confidential-guest-support=tdx0,kernel-irqchip=split,smm=off,sata=off,pic=off,pit=off \
				-object memory-backend-memfd-private,id=ram1,size=4G \
				-machine memory-backend=ram1 \
				-bios "$OVMF" \
				-chardev stdio,id=mux,mux=on \
				-serial chardev:mux \
				-monitor chardev:mux \
				-boot c \
				-drive file="$iso",if=none,id=bootdisk,format=raw,readonly=on \
				-device virtio-blk-pci,drive=bootdisk,bootindex=1,romfile=
		) >"$log_file" 2>&1
		rc=$?
		if grep -q "ChCore shell" "$log_file"; then
			rc=0
		fi
		((rc == 0)) && rc=1
		;;
	*) die "LAUNCH_MODE must be artifact, artifact-fg, or direct" ;;
	esac
	set -e
	cleanup_artifact "$artifact"

	if ((rc == 0)); then
		printf '%s\tPASS\t%s\n' "$target" "$log_file" | tee -a "$OUT/status.tsv"
	else
		printf '%s\tFAIL rc=%s\t%s\n' "$target" "$rc" "$log_file" | tee -a "$OUT/status.tsv"
	fi
}

main() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ $(uname -r) == "$REL" ]] || die "running kernel is $(uname -r), expected $REL"
	[[ -x "$OLD_QEMU" ]] || die "old QEMU missing: $OLD_QEMU"
	[[ -f "$OVMF" ]] || die "OVMF missing: $OVMF"
	[[ $TDX_SMP =~ ^[0-9]+$ && $TDX_SMP -gt 0 ]] || die "invalid COFUNC_TDX_SMP=$TDX_SMP"
	[[ $BOOT_TIMEOUT =~ ^[0-9]+$ && $BOOT_TIMEOUT -gt 0 ]] || die "invalid COFUNC_CVM_BOOT_TIMEOUT=$BOOT_TIMEOUT"
	[[ $LAUNCH_MODE == artifact || $LAUNCH_MODE == artifact-fg || $LAUNCH_MODE == direct ]] || die "LAUNCH_MODE must be artifact, artifact-fg, or direct"
	[[ $QEMU_STRACE == 0 || $QEMU_STRACE == 1 ]] || die "COFUNC_QEMU_STRACE must be 0 or 1"
	[[ $QEMU_NO_REBOOT == 0 || $QEMU_NO_REBOOT == 1 ]] || die "COFUNC_QEMU_NO_REBOOT must be 0 or 1"
	[[ $QEMU_DEBUG == 0 || $QEMU_DEBUG == 1 ]] || die "COFUNC_QEMU_DEBUG must be 0 or 1"
	[[ $QEMU_STRACE == 0 || -x "$(command -v strace)" ]] || die "COFUNC_QEMU_STRACE=1 requested, but strace is missing"

	ensure_mount_rw
	mkdir -p "$OUT"
	{
		echo "kernel=$(uname -a)"
		echo "cmdline=$(cat /proc/cmdline)"
		echo "target=$TARGET"
		echo "launch_mode=$LAUNCH_MODE"
		echo "qemu_strace=$QEMU_STRACE"
		echo "qemu_no_reboot=$QEMU_NO_REBOOT"
		echo "qemu_debug=$QEMU_DEBUG"
		echo "tdx_smp=$TDX_SMP"
		echo "boot_timeout=$BOOT_TIMEOUT"
		echo "qemu=$($OLD_QEMU --version | head -1)"
		echo "ovmf=$OVMF"
		echo "out=$OUT"
	} >"$OUT/run-env.txt"

	case "$TARGET" in
	current) run_one current ;;
	old) run_one old ;;
	both)
		run_one current
		run_one old
		;;
	*) die "TARGET must be current, old, or both" ;;
	esac

	log "done: $OUT"
}

main "$@"
