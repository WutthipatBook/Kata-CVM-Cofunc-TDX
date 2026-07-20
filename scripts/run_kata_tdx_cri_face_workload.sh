#!/usr/bin/env bash
# Compatibility smoke wrapper.  The generic runner owns the CRI implementation.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
WORKLOAD=${WORKLOAD:-fn_py_face_detection}
REPETITIONS=${REPETITIONS:-1}
RUN_DIR=${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_face_workload_$(date -u +%Y%m%d_%H%M%S)}

exec env RUN_DIR="$RUN_DIR" "$BUNDLE/scripts/run_kata_tdx_cri_workload.sh" "$WORKLOAD" "$REPETITIONS"
