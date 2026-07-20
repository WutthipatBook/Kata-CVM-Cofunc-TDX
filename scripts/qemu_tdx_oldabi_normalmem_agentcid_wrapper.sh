#!/usr/bin/env bash
set -euo pipefail

guest_cid=""
for arg in "$@"; do
    if [[ "$arg" == *"guest-cid="* ]]; then
        rest=${arg#*guest-cid=}
        guest_cid=${rest%%,*}
    fi
done

export COFUNC_TDX_WRAPPER_PRIVATE_MEM=0

if [[ -n "$guest_cid" ]]; then
    debug_append="console=ttyS0,115200 earlyprintk=serial,ttyS0,115200 earlycon=uart,io,0x3f8,115200 ignore_loglevel nr_cpus=1 possible_cpus=1"
    agent_append="agent.server_addr=vsock://${guest_cid}:1024"
    current_append=${COFUNC_TDX_WRAPPER_EXTRA_APPEND:-}

    if [[ -z "$current_append" ]]; then
        export COFUNC_TDX_WRAPPER_EXTRA_APPEND="${debug_append} ${agent_append}"
    elif [[ "$current_append" != *"agent.server_addr="* ]]; then
        export COFUNC_TDX_WRAPPER_EXTRA_APPEND="${current_append} ${agent_append}"
    fi
fi

exec /home/booklyn/cofunc-tdx/scripts/qemu_tdx_oldabi_wrapper.sh "$@"
