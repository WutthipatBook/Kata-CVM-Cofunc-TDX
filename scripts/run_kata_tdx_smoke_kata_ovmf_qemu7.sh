#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"

RUN_DIR="${KATA_SMOKE_RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_smoke_oldabi_qemu7_kata_ovmf_$STAMP}"

exec env \
	RUN_DIR="$RUN_DIR" \
	KATA_CONFIG="$BUNDLE/configs/configuration-qemu-tdx-artifact-qemu7-debug-kata-ovmf.toml" \
	TDX_QEMU="$BUNDLE/scripts/qemu_tdx_oldabi_wrapper.sh" \
	TDX_FIRMWARE="/opt/kata/share/ovmf/OVMF.inteltdx.fd" \
	STOP_AFTER_SMOKE=1 \
	KATA_RUN_TIMEOUT="${KATA_RUN_TIMEOUT:-180}" \
	KATA_RETRIES="${KATA_RETRIES:-1}" \
	"$BUNDLE/scripts/run_kata_tdx_fig11.sh"
