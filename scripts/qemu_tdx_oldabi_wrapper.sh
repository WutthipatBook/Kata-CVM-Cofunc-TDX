#!/usr/bin/env bash
set -euo pipefail

REAL_QEMU=${REAL_QEMU:-/mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64}
LOG=${KATA_QEMU_WRAPPER_LOG:-/tmp/kata-qemu-tdx-oldabi-wrapper.$(id -u).log}
QEMU_STDIO_LOG=${COFUNC_TDX_WRAPPER_QEMU_STDIO_LOG:-/tmp/kata-qemu-tdx-oldabi-qemu.$(id -u).log}
PRIVATE_MEM_REWRITE=${COFUNC_TDX_WRAPPER_PRIVATE_MEM:-1}
TDX_ID=${COFUNC_TDX_WRAPPER_TDX_ID:-tdx0}
BIOS_DIR=${COFUNC_TDX_WRAPPER_BIOS_DIR:-/mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/share/qemu}
ADD_BIOS_DIR=${COFUNC_TDX_WRAPPER_ADD_BIOS_DIR:-1}
DISABLE_LEGACY_DEVICES=${COFUNC_TDX_WRAPPER_DISABLE_LEGACY_DEVICES:-0}
DISABLE_HT=${COFUNC_TDX_WRAPPER_DISABLE_HT:-1}
SERIAL_LOG=${COFUNC_TDX_WRAPPER_SERIAL_LOG:-}
CONSOLE_LOG=${COFUNC_TDX_WRAPPER_CONSOLE_LOG:-}
DEBUGCON_LOG=${COFUNC_TDX_WRAPPER_DEBUGCON_LOG:-}
TRACE_LOG=${COFUNC_TDX_WRAPPER_TRACE_LOG:-}
COMPAT_APPEND=${COFUNC_TDX_WRAPPER_COMPAT_APPEND:-nomce}
EXTRA_APPEND=${COFUNC_TDX_WRAPPER_EXTRA_APPEND:-}
SMP_REWRITE=${COFUNC_TDX_WRAPPER_SMP_REWRITE:-}
SMP_REWRITE_FILE=${COFUNC_TDX_WRAPPER_SMP_REWRITE_FILE:-/tmp/cofunc-tdx-wrapper-smp-rewrite}
FWDEBUG_FILE=${COFUNC_TDX_WRAPPER_FWDEBUG_FILE:-/tmp/cofunc-tdx-wrapper-fwdebug}
FWDEBUG=${COFUNC_TDX_WRAPPER_FWDEBUG:-0}

if [[ -z "$SMP_REWRITE" && -r "$SMP_REWRITE_FILE" ]]; then
    IFS= read -r SMP_REWRITE <"$SMP_REWRITE_FILE" || true
fi

rewrite_object() {
    local obj=$1
    local id=tdx

    if [[ "$obj" == *'"qom-type":"tdx-guest"'* || "$obj" == *'"qom-type": "tdx-guest"'* ]]; then
        printf 'tdx-guest,id=%s,sept-ve-disable=on' "$TDX_ID"
        return
    fi

    if [[ "$obj" == tdx-guest,* ]]; then
        obj=$(printf '%s' "$obj" | sed -E "s/(^|,)id=[^,]+/\\1id=${TDX_ID}/")
        if [[ "$obj" != *",sept-ve-disable="* ]]; then
            obj="${obj},sept-ve-disable=on"
        fi
    fi

    if [[ "$PRIVATE_MEM_REWRITE" == "1" && "$obj" == memory-backend-ram,* ]]; then
        obj=${obj/#memory-backend-ram/memory-backend-memfd-private}
    fi

    printf '%s' "$obj"
}

rewrite_device() {
    local dev=$1

    dev=${dev//,iommu_platform=true/}
    dev=${dev//,iommu_platform=on/}
    dev=${dev//,iommu_platform=false/}
    dev=${dev//,iommu_platform=off/}

    if [[ "$dev" == virtio-blk-pci,* && "$dev" != *",romfile="* ]]; then
        dev="${dev},romfile="
    fi

    printf '%s' "$dev"
}

rewrite_chardev() {
    local chardev=$1

    if [[ -n "$CONSOLE_LOG" && "$chardev" == socket,* && "$chardev" == *"id=charconsole0"* ]]; then
        if [[ "$chardev" != *",logfile="* ]]; then
            chardev="${chardev},logfile=${CONSOLE_LOG},logappend=on"
        fi
    fi

    printf '%s' "$chardev"
}

rewrite_global() {
    local global=$1

    if [[ "$global" == *"iommu_platform"* ]]; then
        return 0
    fi
    if [[ "$global" == "kvm-pit.lost_tick_policy="* ]]; then
        return 0
    fi

    printf '%s' "$global"
}

rewrite_machine() {
    local machine=$1

    if [[ "$machine" == *"confidential-guest-support=tdx"* ]]; then
        machine=$(printf '%s' "$machine" | sed -E "s/confidential-guest-support=[^,]+/confidential-guest-support=${TDX_ID}/")
        if [[ "$machine" != *"kernel-irqchip="* && "$machine" != *"kernel_irqchip="* ]]; then
            machine="${machine},kernel-irqchip=split"
        fi
        if [[ "$machine" != *"smm="* ]]; then
            machine="${machine},smm=off"
        fi
        if [[ "$DISABLE_LEGACY_DEVICES" == "1" && "$machine" != *"sata="* ]]; then
            machine="${machine},sata=off"
        fi
        if [[ "$DISABLE_LEGACY_DEVICES" == "1" && "$machine" != *"pic="* ]]; then
            machine="${machine},pic=off"
        fi
        if [[ "$DISABLE_LEGACY_DEVICES" == "1" && "$machine" != *"pit="* ]]; then
            machine="${machine},pit=off"
        fi
        if [[ -n "${private_mem_id:-}" && "$machine" != *"memory-backend="* ]]; then
            machine="${machine},memory-backend=${private_mem_id}"
        fi
    fi

    printf '%s' "$machine"
}

rewrite_cpu() {
    local cpu=$1

    if [[ "$cpu" == host* ]]; then
        if [[ "$cpu" != *"host-phys-bits"* ]]; then
            cpu="${cpu},host-phys-bits"
        fi
        if [[ "$cpu" != *"-intel-pt"* ]]; then
            cpu="${cpu},-intel-pt"
        fi
        if [[ "$DISABLE_HT" == "1" && "$cpu" != *"-ht"* ]]; then
            cpu="${cpu},-ht"
        fi
    fi

    printf '%s' "$cpu"
}

rewrite_append() {
    local cmdline=$1

    if [[ "$has_tdx" == "1" && -n "$COMPAT_APPEND" && "$cmdline" != *"$COMPAT_APPEND"* ]]; then
        cmdline="${cmdline} ${COMPAT_APPEND}"
    fi
    if [[ -n "$EXTRA_APPEND" && "$cmdline" != *"$EXTRA_APPEND"* ]]; then
        cmdline="${cmdline} ${EXTRA_APPEND}"
    fi

    printf '%s' "$cmdline"
}

rewrite_smp() {
    local smp=$1

    if [[ "$has_tdx" == "1" && -n "$SMP_REWRITE" ]]; then
        smp="$SMP_REWRITE"
    fi

    printf '%s' "$smp"
}

args=("$@")
rewritten=()
private_mem_id=""
has_tdx=0
has_no_hpet=0
has_L=0
sandbox_name=""

for ((j = 0; j < ${#args[@]}; j++)); do
    if [[ "${args[$j]}" == "-no-hpet" ]]; then
        has_no_hpet=1
    fi
    if [[ "${args[$j]}" == "-L" ]]; then
        has_L=1
    fi
    if [[ "${args[$j]}" == "-name" && $((j + 1)) -lt ${#args[@]} ]]; then
        sandbox_name=${args[$((j + 1))]%%,*}
    fi
    if [[ "${args[$j]}" == "-object" && $((j + 1)) -lt ${#args[@]} ]]; then
        obj=${args[$((j + 1))]}
        if [[ "$obj" == *"tdx-guest"* ]]; then
            has_tdx=1
        fi
        if [[ "$PRIVATE_MEM_REWRITE" == "1" && "$obj" == memory-backend-ram,* && "$obj" =~ (^|,)id=([^,]+) ]]; then
            private_mem_id=${BASH_REMATCH[2]}
        fi
    fi
    if [[ "${args[$j]}" == "-machine" && $((j + 1)) -lt ${#args[@]} && "${args[$((j + 1))]}" == *"confidential-guest-support=tdx"* ]]; then
        has_tdx=1
    fi
done

if [[ "$has_tdx" == "1" && ( "$FWDEBUG" == "1" || -f "$FWDEBUG_FILE" ) ]]; then
    debug_suffix="$(id -u)"
    if [[ -n "$sandbox_name" ]]; then
        debug_suffix=${sandbox_name//[^A-Za-z0-9_.-]/_}
    fi
    SERIAL_LOG=${SERIAL_LOG:-/tmp/kata-qemu-tdx-oldabi-serial.${debug_suffix}.log}
    CONSOLE_LOG=${CONSOLE_LOG:-/tmp/kata-qemu-tdx-oldabi-console.${debug_suffix}.log}
    DEBUGCON_LOG=${DEBUGCON_LOG:-/tmp/kata-qemu-tdx-oldabi-debugcon.${debug_suffix}.log}
    TRACE_LOG=${TRACE_LOG:-/tmp/kata-qemu-tdx-oldabi-trace.${debug_suffix}.log}
    EXTRA_APPEND=${EXTRA_APPEND:-console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 earlycon=uart,io,0x3f8,115200 ignore_loglevel nr_cpus=1 possible_cpus=1}
fi

if [[ "$ADD_BIOS_DIR" == "1" && "$has_tdx" == "1" && "$has_L" == "0" && -d "$BIOS_DIR" ]]; then
    rewritten+=("-L" "$BIOS_DIR")
fi
if [[ "$has_tdx" == "1" && "$has_no_hpet" == "0" ]]; then
    rewritten+=("-no-hpet")
fi

i=0
while (( i < ${#args[@]} )); do
    arg=${args[$i]}
    if [[ "$arg" == "-object" && $((i + 1)) -lt ${#args[@]} ]]; then
        rewritten+=("$arg")
        rewritten+=("$(rewrite_object "${args[$((i + 1))]}")")
        i=$((i + 2))
        continue
    fi
    if [[ "$arg" == "-device" && $((i + 1)) -lt ${#args[@]} ]]; then
        rewritten+=("$arg")
        rewritten+=("$(rewrite_device "${args[$((i + 1))]}")")
        i=$((i + 2))
        continue
    fi
    if [[ "$arg" == "-chardev" && $((i + 1)) -lt ${#args[@]} ]]; then
        rewritten+=("$arg")
        rewritten+=("$(rewrite_chardev "${args[$((i + 1))]}")")
        i=$((i + 2))
        continue
    fi
    if [[ "$arg" == "-global" && $((i + 1)) -lt ${#args[@]} ]]; then
        global_arg=$(rewrite_global "${args[$((i + 1))]}")
        if [[ -n "$global_arg" ]]; then
            rewritten+=("$arg")
            rewritten+=("$global_arg")
        fi
        i=$((i + 2))
        continue
    fi
    if [[ "$arg" == "-machine" && $((i + 1)) -lt ${#args[@]} ]]; then
        rewritten+=("$arg")
        rewritten+=("$(rewrite_machine "${args[$((i + 1))]}")")
        i=$((i + 2))
        continue
    fi
    if [[ "$arg" == "-cpu" && $((i + 1)) -lt ${#args[@]} ]]; then
        rewritten+=("$arg")
        rewritten+=("$(rewrite_cpu "${args[$((i + 1))]}")")
        i=$((i + 2))
        continue
    fi
    if [[ "$arg" == "-append" && $((i + 1)) -lt ${#args[@]} ]]; then
        rewritten+=("$arg")
        rewritten+=("$(rewrite_append "${args[$((i + 1))]}")")
        i=$((i + 2))
        continue
    fi
    if [[ "$arg" == "-smp" && $((i + 1)) -lt ${#args[@]} ]]; then
        rewritten+=("$arg")
        rewritten+=("$(rewrite_smp "${args[$((i + 1))]}")")
        i=$((i + 2))
        continue
    fi
    if [[ "$arg" == "-numa" && $((i + 1)) -lt ${#args[@]} ]]; then
        if [[ -n "$private_mem_id" && "${args[$((i + 1))]}" == *"memdev=${private_mem_id}"* ]]; then
            i=$((i + 2))
            continue
        fi
        rewritten+=("$arg")
        rewritten+=("${args[$((i + 1))]}")
        i=$((i + 2))
        continue
    fi

    rewritten+=("$(rewrite_object "$arg")")
    i=$((i + 1))
done

if [[ "$has_tdx" == "1" && -n "$SERIAL_LOG" ]]; then
    rewritten+=("-serial" "file:${SERIAL_LOG}")
fi
if [[ "$has_tdx" == "1" && -n "$DEBUGCON_LOG" ]]; then
    rewritten+=("-debugcon" "file:${DEBUGCON_LOG}" "-global" "isa-debugcon.iobase=0x402")
fi
if [[ "$has_tdx" == "1" && -n "$TRACE_LOG" ]]; then
    rewritten+=("-trace" "enable=kvm_tdx_init_mem_region,file=${TRACE_LOG}")
fi

if [[ -n "$LOG" ]]; then
    {
        printf '[%s] original:' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf ' %q' "$REAL_QEMU" "${args[@]}"
        printf '\n[%s] rewritten:' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf ' %q' "$REAL_QEMU" "${rewritten[@]}"
        printf '\n'
    } >>"$LOG" 2>/dev/null || true
fi

if [[ "$has_tdx" == "1" && -n "$QEMU_STDIO_LOG" ]]; then
    {
        printf '[%s] exec:' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf ' %q' "$REAL_QEMU" "${rewritten[@]}"
        printf '\n'
    } >>"$QEMU_STDIO_LOG" 2>/dev/null || true

    set +e
    "$REAL_QEMU" "${rewritten[@]}" >>"$QEMU_STDIO_LOG" 2>&1
    rc=$?
    set -e
    {
        printf '[%s] exit rc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rc"
    } >>"$QEMU_STDIO_LOG" 2>/dev/null || true
    exit "$rc"
fi

exec "$REAL_QEMU" "${rewritten[@]}"
