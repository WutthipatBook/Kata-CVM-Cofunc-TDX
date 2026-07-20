#!/usr/bin/env bash
#
# Long-running crash recorder for CoFunc host experiments.
# It writes line-buffered logs and syncs after each record so a hard reset is
# more likely to leave the last few events on disk.

set -euo pipefail

RUN_ID=${RUN_ID:-cofunc_flight_$(date -u +%Y%m%d_%H%M%S)}
TRACE_ROOT=${TRACE_ROOT:-/var/tmp/cofunc-flight}
INTERVAL=${INTERVAL:-1}

usage() {
        sed -n '2,7p' "$0" >&2
}

while [ "$#" -gt 0 ]; do
        case "$1" in
                --daemon)
                        shift
                        mkdir -p "${TRACE_ROOT}"
                        export RUN_ID TRACE_ROOT INTERVAL
                        nohup "$0" "$@" >"${TRACE_ROOT}/${RUN_ID}.nohup" 2>&1 &
                        echo $!
                        exit 0
                        ;;
                --run-id)
                        RUN_ID=$2
                        shift 2
                        ;;
                --trace-root)
                        TRACE_ROOT=$2
                        shift 2
                        ;;
                --interval)
                        INTERVAL=$2
                        shift 2
                        ;;
                --help|-h)
                        usage
                        exit 0
                        ;;
                *)
                        usage
                        exit 2
                        ;;
        esac
done

TRACE_DIR=${TRACE_ROOT}/${RUN_ID}
mkdir -p "${TRACE_DIR}"

append_sync() {
        local file=$1
        shift

        printf '[%s] ' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >>"${file}"
        printf '%s' "$*" >>"${file}"
        printf '\n' >>"${file}"
        sync -f "${file}" 2>/dev/null || sync
}

capture_once() {
        local name=$1
        shift
        {
                printf '$'
                printf ' %q' "$@"
                printf '\n'
                "$@"
        } >"${TRACE_DIR}/${name}.log" 2>&1 || true
        sync -f "${TRACE_DIR}/${name}.log" 2>/dev/null || sync
}

stop_children() {
        for pid_file in "${TRACE_DIR}"/*.pid; do
                [ -f "${pid_file}" ] || continue
                pid=$(cat "${pid_file}" 2>/dev/null || true)
                [ -n "${pid}" ] || continue
                [ "${pid}" != "$$" ] || continue
                kill "${pid}" 2>/dev/null || true
        done
}

trap stop_children EXIT

echo $$ >"${TRACE_DIR}/recorder.pid"
append_sync "${TRACE_DIR}/flight.log" "trace_dir=${TRACE_DIR}"
capture_once uname uname -a
capture_once boot_id cat /proc/sys/kernel/random/boot_id
capture_once cmdline cat /proc/cmdline
capture_once mounts findmnt
capture_once kvm_symbols bash -lc "grep -E ' split_container_| KVM_SC_|kvm_dev_ioctl_sc_get_vm|kvm_vm_ioctl_sc_alloc_vcpu' /proc/kallsyms | sort"
capture_once dmesg_snapshot bash -lc "dmesg --time-format=iso | tail -300"

(
        if command -v stdbuf >/dev/null 2>&1; then
                stdbuf -oL -eL dmesg --follow-new --time-format=iso
        else
                dmesg --follow-new
        fi | while IFS= read -r line; do
                append_sync "${TRACE_DIR}/dmesg-follow.log" "${line}"
        done
) &
echo $! >"${TRACE_DIR}/dmesg-follow.pid"

(
        while true; do
                {
                        printf 'time=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
                        printf 'boot_id=%s\n' "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
                        printf 'uptime=%s\n' "$(cat /proc/uptime 2>/dev/null || true)"
                        printf 'loadavg=%s\n' "$(cat /proc/loadavg 2>/dev/null || true)"
                        printf 'mem_available_kb=%s\n' "$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || true)"
                        pgrep -a qemu-system-x86_64 || true
                        pgrep -a sc-runtime || true
                        pgrep -a docker || true
                        printf '%s\n' '---'
                } >>"${TRACE_DIR}/heartbeat.log" 2>&1
                sync -f "${TRACE_DIR}/heartbeat.log" 2>/dev/null || sync
                sleep "${INTERVAL}"
        done
) &
echo $! >"${TRACE_DIR}/heartbeat.pid"

append_sync "${TRACE_DIR}/flight.log" "started"

while true; do
        sleep 3600
done
