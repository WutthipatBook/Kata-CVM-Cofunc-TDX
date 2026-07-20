#!/usr/bin/env bash
set -euo pipefail

export REAL_QEMU=/mnt/new_disk/cofunc_tdx_artifact/install/qemu-ubuntu-tdx/bin/qemu-system-x86_64
export COFUNC_TDX_WRAPPER_PRIVATE_MEM=0

exec /home/booklyn/cofunc-tdx/scripts/qemu_tdx_oldabi_wrapper.sh "$@"
