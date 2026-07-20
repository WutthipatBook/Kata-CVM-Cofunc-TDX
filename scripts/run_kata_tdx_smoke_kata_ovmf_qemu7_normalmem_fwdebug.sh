#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
KATA_CONFIG="${KATA_CONFIG:-$BUNDLE/configs/configuration-qemu-tdx-artifact-qemu7-debug-kata-ovmf-normalmem.toml}"
TDX_QEMU="${TDX_QEMU:-$BUNDLE/scripts/qemu_tdx_oldabi_normalmem_wrapper.sh}"

RUN_DIR="${KATA_SMOKE_RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_smoke_oldabi_qemu7_kata_ovmf_normalmem_fwdebug_$STAMP}"
FWDEBUG_FILE="${FWDEBUG_FILE:-/tmp/cofunc-tdx-wrapper-fwdebug}"
SMP_REWRITE_FILE="${COFUNC_TDX_WRAPPER_SMP_REWRITE_FILE:-/tmp/cofunc-tdx-wrapper-smp-rewrite}"
SMP_REWRITE="${COFUNC_TDX_WRAPPER_SMP_REWRITE:-}"
CREATED_SMP_REWRITE_FILE=0

mkdir -p "$RUN_DIR"
printf '1\n' >"$FWDEBUG_FILE"
if [[ -n "$SMP_REWRITE" ]]; then
	printf '%s\n' "$SMP_REWRITE" >"$SMP_REWRITE_FILE"
	CREATED_SMP_REWRITE_FILE=1
fi

cleanup() {
	rm -f "$FWDEBUG_FILE"
	if [[ "$CREATED_SMP_REWRITE_FILE" == 1 ]]; then
		rm -f "$SMP_REWRITE_FILE"
	fi
}
trap cleanup EXIT

env \
	RUN_DIR="$RUN_DIR" \
	KATA_CONFIG="$KATA_CONFIG" \
	TDX_QEMU="$TDX_QEMU" \
	TDX_FIRMWARE="/opt/kata/share/ovmf/OVMF.inteltdx.fd" \
	STOP_AFTER_SMOKE=1 \
	KATA_RUN_TIMEOUT="${KATA_RUN_TIMEOUT:-180}" \
	KATA_RETRIES="${KATA_RETRIES:-1}" \
	"$BUNDLE/scripts/run_kata_tdx_fig11.sh"
