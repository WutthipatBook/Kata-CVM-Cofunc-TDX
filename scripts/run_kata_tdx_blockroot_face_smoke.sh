#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
STAMP=$(date -u +%Y%m%d_%H%M%S)
RUN_DIR=${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_blockroot_face_smoke_$STAMP}

exec env \
    ARTIFACT_DIR="$ROOT/cofunc-artifact" \
    LOG_DIR="$RUN_DIR/log" \
    RUN_LOG="$RUN_DIR/runner.log" \
    KATA_CONFIG="$BUNDLE/configs/configuration-qemu-tdx-artifact-qemu7-blockroot-normalmem.toml" \
    KATA_RUNTIME_TYPE="io.containerd.kata-qemu-tdx.v2" \
    CONTAINERD_SNAPSHOTTER=blockfile \
    CONTAINERD_PLATFORM=linux/amd64 \
    CONTAINERD_NETWORK_MODE="${CONTAINERD_NETWORK_MODE:-none}" \
    KATA_QEMU_WRAPPER_LOG="$RUN_DIR/qemu-wrapper.log" \
    COFUNC_TDX_WRAPPER_QEMU_STDIO_LOG="$RUN_DIR/qemu.log" \
    COFUNC_TDX_WRAPPER_SERIAL_LOG="$RUN_DIR/guest-serial.log" \
    KATA_RUN_TIMEOUT="${KATA_RUN_TIMEOUT:-300}" \
    "$BUNDLE/scripts/run_kata_tdx_workload.sh" fn_py_face_detection 1
