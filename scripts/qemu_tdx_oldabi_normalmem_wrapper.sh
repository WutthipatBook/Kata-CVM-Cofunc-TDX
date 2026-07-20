#!/usr/bin/env bash
set -euo pipefail

export COFUNC_TDX_WRAPPER_PRIVATE_MEM=0
exec /home/booklyn/cofunc-tdx/scripts/qemu_tdx_oldabi_wrapper.sh "$@"
