#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/mnt/new_disk/cofunc_tdx_artifact"
ARTIFACT="$ROOT/cofunc-artifact-oldabi"
TOOLS="$ARTIFACT/testcases/tools"
TASK="$TOOLS/tasks/run_sc_fork"
SUMMARY_TOOL="/home/booklyn/cofunc-tdx/scripts/cofunc_tdx_sc_fork_summary.py"
REL="5.19.0-cofunc-tdx-5.19+"

OUT="${OUT:-$ROOT/results/oldabi_5_19_fig11_$(date -u +%Y%m%d_%H%M%S)}"
LOG_DIR="$OUT/log"
SMOKE_LOG_DIR="$OUT/smoke-log"
TRACE_ROOT="$OUT/cofunc-trace"
WORKLOAD_TIMEOUT_SEC="${COFUNC_WORKLOAD_TIMEOUT_SEC:-1200}"
STOP_AFTER_SMOKE="${STOP_AFTER_SMOKE:-0}"
SKIP_FACE_SMOKE="${COFUNC_OLDABI_SKIP_FACE_SMOKE:-0}"
HOST_PYTHON_SITE="${HOST_PYTHON_SITE:-/home/booklyn/.local/lib/python3.10/site-packages}"
TDX_SMP="${COFUNC_TDX_SMP:-16}"
KVM_BUSY_RETRIES="${COFUNC_KVM_BUSY_RETRIES:-3}"
KVM_BUSY_COOLDOWN_SEC="${COFUNC_KVM_BUSY_COOLDOWN_SEC:-20}"
RUN_START_EPOCH=""

FIG11_WORKLOADS=(
	"fn_py_compression"
	"fn_py_face_detection"
	"fn_py_image_processing"
	"fn_py_sentiment"
	"fn_py_video_processing"
	"fn_py_dna_visualisation"
	"fn_js_thumbnailer"
	"fn_js_uploader"
	"chain_js_alexa/fn_js_alexa_frontend"
	"chain_js_alexa/fn_js_alexa_interact"
	"chain_js_alexa/fn_js_alexa_smarthome"
	"chain_js_alexa/fn_js_alexa_tv"
)

if [[ -n ${COFUNC_OLDABI_RUNTIME_WORKLOADS:-} ]]; then
	# shellcheck disable=SC2206
	FIG11_WORKLOADS=(${COFUNC_OLDABI_RUNTIME_WORKLOADS})
fi

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

cleanup() {
	local rc=$?
	set +e
	if [[ -d ${OUT:-} ]]; then
		dmesg -T >"$OUT/dmesg-final.log" 2>/dev/null
		if [[ -n ${RUN_START_EPOCH:-} ]] && command -v journalctl >/dev/null 2>&1; then
			journalctl -k --since "@$RUN_START_EPOCH" --no-pager \
				>"$OUT/kernel-journal-since-start.log" 2>/dev/null || true
		fi
		docker ps -a >"$OUT/docker-ps-final.log" 2>/dev/null
		screen -ls >"$OUT/screen-final.log" 2>&1
	fi
	cleanup_cvm_state
	if [[ -x $TASK/cleanup.sh ]]; then
		"$TASK/cleanup.sh" >/dev/null 2>&1 || true
	fi
	exit "$rc"
}

require_root() {
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
}

ensure_mount_rw() {
	local opts
	findmnt /mnt/new_disk >/dev/null || die "/mnt/new_disk is not mounted"
	opts=$(findmnt -no OPTIONS /mnt/new_disk)
	if [[ ,$opts, == *,ro,* ]]; then
		log "remounting /mnt/new_disk read-write"
		mount -o remount,rw /mnt/new_disk
	fi
	opts=$(findmnt -no OPTIONS /mnt/new_disk)
	[[ ,$opts, == *,rw,* ]] || die "/mnt/new_disk is still not read-write: $opts"
}

require_paths() {
	[[ $(uname -r) == "$REL" ]] || die "running kernel is $(uname -r), expected $REL"
	[[ -e /dev/kvm ]] || die "/dev/kvm is missing"
	[[ -r /sys/module/kvm_intel/parameters/tdx ]] || die "kvm_intel tdx parameter missing"
	[[ $(cat /sys/module/kvm_intel/parameters/tdx) == "Y" ]] || die "kvm_intel.tdx is not Y"
	[[ -x "$ROOT/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64" ]] || die "old QEMU missing"
	[[ -f "$ROOT/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd" ]] || die "TDX OVMF missing"
	[[ -f "$ARTIFACT/cvm_os/build/chcore.iso" ]] || die "old-ABI ChCore ISO missing"
	[[ -x "$ARTIFACT/cvm_os/build/simulate.sh" ]] || die "old-ABI simulate.sh missing"
	[[ -x "$TASK/action.sh" ]] || die "run_sc_fork action missing"
	[[ -x "$TASK/prepare.sh" ]] || die "run_sc_fork prepare missing"
	[[ -x "$TASK/cleanup.sh" ]] || die "run_sc_fork cleanup missing"
	[[ -x "$SUMMARY_TOOL" ]] || die "summary tool missing"
	[[ -d "$HOST_PYTHON_SITE/boto3" ]] || die "boto3 missing under HOST_PYTHON_SITE=$HOST_PYTHON_SITE"
	[[ $SKIP_FACE_SMOKE == 0 || $SKIP_FACE_SMOKE == 1 ]] \
		|| die "COFUNC_OLDABI_SKIP_FACE_SMOKE must be 0 or 1, got $SKIP_FACE_SMOKE"
	[[ $TDX_SMP =~ ^[0-9]+$ && $TDX_SMP -gt 0 ]] || die "invalid COFUNC_TDX_SMP=$TDX_SMP"
	[[ $KVM_BUSY_RETRIES =~ ^[0-9]+$ && $KVM_BUSY_RETRIES -gt 0 ]] || die "invalid COFUNC_KVM_BUSY_RETRIES=$KVM_BUSY_RETRIES"
	[[ $KVM_BUSY_COOLDOWN_SEC =~ ^[0-9]+$ ]] || die "invalid COFUNC_KVM_BUSY_COOLDOWN_SEC=$KVM_BUSY_COOLDOWN_SEC"
}

write_selected_params() {
	local params="$OUT/run_sc_fork.params"
	python3 - "$TASK/params" "$params" "${FIG11_WORKLOADS[@]}" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
wanted = sys.argv[3:]
rows = {}
for line in src.read_text().splitlines():
    if not line.strip():
        continue
    fn, times = line.split()[:2]
    rows[fn] = times
missing = [fn for fn in wanted if fn not in rows]
if missing:
    raise SystemExit("missing workload params: " + ", ".join(missing))
dst.write_text("\n".join(f"{fn} {rows[fn]}" for fn in wanted) + "\n")
PY
}

cleanup_cvm_state() {
	(
		set +e
		cd "$ARTIFACT/testcases" || exit 0
		export COFUNC_CVM_USE_SUDO=0
		"$TOOLS/sc-snapshot.sh" clean >/dev/null 2>&1
		"$TOOLS/cvm.sh" clean >/dev/null 2>&1
		"$TOOLS/lean_container/rootfs.sh" clean >/dev/null 2>&1
		"$TOOLS/lean_container/cgroup.sh" clean >/dev/null 2>&1
	) || true
}

is_retryable_cvm_boot_failure() {
	local run_log=$1

	grep -Eq \
		'Timed out waiting for ChCore shell|CVM screen session exited before ChCore shell|handle_perm_fault failed: fault_addr=400000 desired_perm=1|CMD:[[:space:]]+/procmgr\.srv' \
		"$run_log"
}

run_action() {
	local fn=$1
	local times=$2
	local log_root=$3
	local base_run_log="$OUT/run-$(echo "$fn" | tr '/' '_')-${times}.log"
	local attempt run_log rc

	for ((attempt = 1; attempt <= KVM_BUSY_RETRIES; attempt++)); do
		run_log="${base_run_log%.log}-attempt-${attempt}.log"
		log "running $fn times=$times attempt=$attempt/$KVM_BUSY_RETRIES"
		cleanup_cvm_state
		set +e
		(
			cd "$ARTIFACT/testcases"
			export LOG_DIR="$log_root"
			export COFUNC_TRACE_ROOT="$TRACE_ROOT"
			export COFUNC_TDX_QEMU="$ROOT/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64"
			export COFUNC_TDX_OVMF="$ROOT/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd"
			export COFUNC_TDX_QEMU_BIOS_DIR="$ROOT/install/qemu-tdx-2022-09-01-cofunc/share/qemu"
			export COFUNC_TDX_SMP="$TDX_SMP"
			export COFUNC_CVM_USE_SUDO=0
			export COFUNC_CVM_BOOT_TIMEOUT="${COFUNC_CVM_BOOT_TIMEOUT:-240}"
			export PYTHONPATH="$HOST_PYTHON_SITE${PYTHONPATH:+:$PYTHONPATH}"
			timeout --kill-after=30s "$WORKLOAD_TIMEOUT_SEC" "$TASK/action.sh" "$fn" "$times"
		) >"$run_log" 2>&1
		rc=$?
		set -e
		cp -a "$run_log" "$base_run_log" 2>/dev/null || true
		if ((rc == 0)); then
			return 0
		fi
		if grep -Eq 'KVM_CREATE_VM.*Device or resource busy|failed to initialize kvm: Device or resource busy' "$run_log" && ((attempt < KVM_BUSY_RETRIES)); then
			log "KVM_CREATE_VM returned busy; cleaning CVM state and waiting ${KVM_BUSY_COOLDOWN_SEC}s"
			cleanup_cvm_state
			sleep "$KVM_BUSY_COOLDOWN_SEC"
			continue
		fi
		if is_retryable_cvm_boot_failure "$run_log" && ((attempt < KVM_BUSY_RETRIES)); then
			log "CVM boot did not reach ChCore shell; cleaning CVM state and waiting ${KVM_BUSY_COOLDOWN_SEC}s"
			cleanup_cvm_state
			sleep "$KVM_BUSY_COOLDOWN_SEC"
			continue
		fi
		return "$rc"
	done
}

main() {
	require_root
	ensure_mount_rw
	require_paths

	mkdir -p "$OUT" "$LOG_DIR" "$SMOKE_LOG_DIR" "$TRACE_ROOT"
	RUN_START_EPOCH="$(date -u +%s)"
	{
		echo "run_start_epoch=$RUN_START_EPOCH"
		echo "run_start_utc=$(date -u -d "@$RUN_START_EPOCH" +%Y-%m-%dT%H:%M:%SZ)"
	} >"$OUT/run-start.txt"
	cp "$ARTIFACT/plots/fig11.txt" "$OUT/fig11_expected.txt"
	write_selected_params

	{
		echo "kernel=$(uname -a)"
		echo "cmdline=$(cat /proc/cmdline)"
		echo "mount=$(findmnt /mnt/new_disk)"
		echo "qemu=$($ROOT/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64 --version | head -1)"
		echo "out=$OUT"
		echo "workload_timeout_sec=$WORKLOAD_TIMEOUT_SEC"
		echo "stop_after_smoke=$STOP_AFTER_SMOKE"
		echo "skip_face_smoke=$SKIP_FACE_SMOKE"
		echo "regular_memfile=${COFUNC_OLDABI_REGULAR_MEMFILE:-0}"
		echo "host_python_site=$HOST_PYTHON_SITE"
		echo "tdx_smp=$TDX_SMP"
		echo "kvm_busy_retries=$KVM_BUSY_RETRIES"
		echo "kvm_busy_cooldown_sec=$KVM_BUSY_COOLDOWN_SEC"
		echo "thp_enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)"
		echo "thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true)"
		printf 'selected_workloads='
		printf '%s ' "${FIG11_WORKLOADS[@]}"
		printf '\n'
	} >"$OUT/run-env.txt"

	trap cleanup EXIT

	log "starting helper environment"
	"$TASK/prepare.sh"

	if [[ $SKIP_FACE_SMOKE == 0 ]]; then
		log "smoke: fn_py_face_detection x1"
		run_action "fn_py_face_detection" 1 "$SMOKE_LOG_DIR"
		"$SUMMARY_TOOL" "$SMOKE_LOG_DIR" --expected "$OUT/fig11_expected.txt" | tee "$OUT/smoke-summary.txt"
	else
		log "COFUNC_OLDABI_SKIP_FACE_SMOKE=1, skipping mandatory face-detection smoke"
	fi

	if [[ $STOP_AFTER_SMOKE == 1 ]]; then
		log "STOP_AFTER_SMOKE=1, stopping after smoke"
		exit 0
	fi

	while read -r fn times; do
		[[ -n ${fn:-} ]] || continue
		run_action "$fn" "$times" "$LOG_DIR"
	done <"$OUT/run_sc_fork.params"

	"$SUMMARY_TOOL" "$LOG_DIR" --expected "$OUT/fig11_expected.txt" | tee "$OUT/tdx_sc_fork_summary.txt"
	log "done: $OUT"
}

main "$@"
