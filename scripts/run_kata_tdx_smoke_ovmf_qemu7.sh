#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"

RUN_DIR="${KATA_SMOKE_RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_smoke_oldabi_qemu7_direct_kernel_fwcfg_$STAMP}"

exec env \
	RUN_DIR="$RUN_DIR" \
	KATA_CONFIG="$BUNDLE/configs/configuration-qemu-tdx-artifact-qemu7-debug.toml" \
	TDX_QEMU="$BUNDLE/scripts/qemu_tdx_oldabi_wrapper.sh" \
	TDX_FIRMWARE="$ROOT/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd" \
	STOP_AFTER_SMOKE=1 \
	KATA_RUN_TIMEOUT="${KATA_RUN_TIMEOUT:-180}" \
	KATA_RETRIES="${KATA_RETRIES:-1}" \
	"$BUNDLE/scripts/run_kata_tdx_fig11.sh"
