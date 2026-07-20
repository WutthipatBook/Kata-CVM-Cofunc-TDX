#!/bin/bash -e

cvm_path=$(dirname "$0")/../../cvm_os
slot_id=${SLOT_ID:-0}
session=split-container-cvm-${slot_id}
use_sudo=${COFUNC_CVM_USE_SUDO:-1}
boot_timeout=${COFUNC_CVM_BOOT_TIMEOUT:-180}
trace_root=${COFUNC_TRACE_ROOT:-/var/tmp/cofunc-trace}

max_vcpus=$(cat /sys/module/kvm_intel/parameters/max_vcpus 2>/dev/null || true)
if [[ -z $max_vcpus ]]; then
        max_vcpus=$(cat /sys/module/kvm/parameters/max_vcpus 2>/dev/null || true)
fi
if [[ -z $max_vcpus ]]; then
        max_vcpus=32
fi
tdx_smp=${COFUNC_TDX_SMP:-$max_vcpus}

run_maybe_sudo() {
        if [[ $use_sudo == 1 ]]; then
                sudo "$@"
        else
                "$@"
        fi
}

clean() {
        until [[ -z $(pidof qemu-system-x86_64) ]]; do
                run_maybe_sudo pkill -9 qemu &>/dev/null || true
        done
        run_maybe_sudo screen -X -S "$session" quit &>/dev/null || true
}

if [[ ${1:-} == "clean" ]]; then
        clean
        exit 0
fi

if [[ -z ${SLOT_ID:-} ]]; then
        clean
fi

pushd "$cvm_path"

exec_log=exec_log_${slot_id}
trace_dir=${trace_root}/cvm-${slot_id}-$(date -u +%Y%m%d_%H%M%S)
mkdir -p "$trace_dir" 2>/dev/null || true

run_maybe_sudo rm -f "$exec_log"
touch "$exec_log"

{
        printf 'slot=%s\n' "$slot_id"
        printf 'session=%s\n' "$session"
        printf 'cwd=%s\n' "$PWD"
        printf 'boot_timeout=%s\n' "$boot_timeout"
        printf 'max_vcpus=%s\n' "$max_vcpus"
        printf 'tdx_smp=%s\n' "$tdx_smp"
        printf 'qemu=%s\n' "${COFUNC_TDX_QEMU:-/mnt/nvme_500g/cofunc_tdx_artifact/install/qemu-ubuntu-tdx/bin/qemu-system-x86_64}"
        uname -a
        "${COFUNC_TDX_QEMU:-/mnt/nvme_500g/cofunc_tdx_artifact/install/qemu-ubuntu-tdx/bin/qemu-system-x86_64}" --version 2>&1 | head -5 || true
        cp -a build/simulate.sh "$trace_dir/simulate.sh" 2>/dev/null || true
} >"$trace_dir/launch-env.log" 2>&1 || true

run_maybe_sudo env \
	SLOT_ID="$slot_id" \
	COFUNC_TDX_SMP="$tdx_smp" \
	COFUNC_TDX_QEMU="${COFUNC_TDX_QEMU:-/mnt/nvme_500g/cofunc_tdx_artifact/install/qemu-ubuntu-tdx/bin/qemu-system-x86_64}" \
	COFUNC_TDX_OVMF="${COFUNC_TDX_OVMF:-/mnt/nvme_500g/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd}" \
	COFUNC_TDX_QEMU_BIOS_DIR="${COFUNC_TDX_QEMU_BIOS_DIR:-/usr/share/qemu}" \
	COFUNC_TRACE_DIR="$trace_dir" \
	COFUNC_GDB_PORT_FILE="$trace_dir/gdb-port" \
	screen -L -Logfile "$trace_dir/screen.log" -dmS "$session" build/simulate.sh

start_ts=$(date +%s)
until grep -q "ChCore shell" "$exec_log"; do
        if ! run_maybe_sudo screen -list | grep -Fq ".$session"; then
                cp -a "$exec_log" "$trace_dir/$exec_log.failed" 2>/dev/null || true
                echo "CVM screen session exited before ChCore shell; see $trace_dir and $cvm_path/$exec_log" >&2
                tail -n 80 "$exec_log" >&2 || true
                tail -n 80 "$trace_dir/screen.log" >&2 || true
                exit 1
        fi
        now_ts=$(date +%s)
        if (( now_ts - start_ts >= boot_timeout )); then
                cp -a "$exec_log" "$trace_dir/$exec_log.timeout" 2>/dev/null || true
                echo "Timed out waiting for ChCore shell after ${boot_timeout}s; see $trace_dir and $cvm_path/$exec_log" >&2
                tail -n 80 "$exec_log" >&2 || true
                tail -n 80 "$trace_dir/screen.log" >&2 || true
                exit 1
        fi
        sleep 1
done
cp -a "$exec_log" "$trace_dir/$exec_log.ready" 2>/dev/null || true

popd
