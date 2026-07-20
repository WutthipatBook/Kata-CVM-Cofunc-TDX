#!/usr/bin/env bash
set -u

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG=${KATA_CONFIG:-/home/booklyn/cofunc-tdx/configs/configuration-qemu-tdx-artifact-qemu7-debug.toml}
TIMEOUT=${KATA_RUN_TIMEOUT:-90}
SINCE=${SINCE:-15 minutes ago}
RUN_BASE=${RUN_BASE:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_manual_$(date -u +%Y%m%d_%H%M%S)}

export KATA_CONFIG="$CONFIG"
export KATA_RUN_TIMEOUT="$TIMEOUT"
export LOG_DIR=${LOG_DIR:-$RUN_BASE/log}
export RUN_LOG=${RUN_LOG:-$RUN_BASE/runner.log}
export KATA_QEMU_WRAPPER_LOG=${KATA_QEMU_WRAPPER_LOG:-$RUN_BASE/qemu-wrapper.log}

rm -f /tmp/kata-qemu-tdx-oldabi-wrapper*.log 2>/dev/null || true

set +e
"$SCRIPT_DIR/run_kata_tdx_workload.sh" "$@"
rc=$?
set -e

if (( rc != 0 )); then
    out=${OUT:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_artifact_qemu7_debug_$(date -u +%Y%m%d_%H%M%S)}
    echo "Kata artifact-QEMU probe failed with rc=$rc; collecting debug to $out" >&2
    OUT="$out" SINCE="$SINCE" KATA_CONFIG="$CONFIG" \
        "$SCRIPT_DIR/collect_kata_tdx_debug.sh" >&2 || true
fi

exit "$rc"
