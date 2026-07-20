#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"

export KATA_CONFIG="${KATA_CONFIG:-$BUNDLE/configs/configuration-qemu-tdx-artifact-qemu7-debug-kata24-agent-noavx512-normalmem.toml}"
export KATA_SMOKE_RUN_DIR="${KATA_SMOKE_RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_smoke_oldabi_qemu7_kata24_agent_noavx512_normalmem_fwdebug_$STAMP}"

exec "$BUNDLE/scripts/run_kata_tdx_smoke_kata_ovmf_qemu7_normalmem_fwdebug.sh" "$@"
