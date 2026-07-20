#!/usr/bin/env bash
set -euo pipefail

export KATA_CONFIG=${KATA_CONFIG:-/home/booklyn/cofunc-tdx/configs/configuration-qemu-tdx-artifact-qemu10-debug.toml}
export OUT=${OUT:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_artifact_qemu10_debug_$(date -u +%Y%m%d_%H%M%S)}

exec /home/booklyn/cofunc-tdx/scripts/run_kata_tdx_artifact_qemu7_probe.sh "$@"
