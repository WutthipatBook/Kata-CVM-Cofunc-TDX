#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ARTIFACT="/mnt/nvme_500g/cofunc_tdx_artifact/cofunc-artifact"
OUT=""
WORKLOADS=""
SKIP_BUILD=0
KEEP_HELPERS=0
KEEP_GOING=0
NO_CLEANUP=0
STOP_CONFLICTS=1
PREPARE_PERFORMANCE=0
REQUIRE_PERFORMANCE=0
CORE_ISOLATED=0
TASKSET_CPUS=""
BOOT_ISOLATED_CPUS=""
TDX_SMP="${COFUNC_TDX_SMP:-auto}"
TDX_VM_COOLDOWN_SEC="${COFUNC_TDX_VM_COOLDOWN_SEC:-5}"
KVM_CREATE_VM_BUSY_RETRIES="${COFUNC_KVM_CREATE_VM_BUSY_RETRIES:-2}"
KVM_CREATE_VM_BUSY_COOLDOWN_SEC="${COFUNC_KVM_CREATE_VM_BUSY_COOLDOWN_SEC:-10}"
WORKLOAD_TIMEOUT_SEC="${COFUNC_WORKLOAD_TIMEOUT_SEC:-900}"
QUIET_WORKLOAD_OUTPUT=0
EXPECTED_KVM_SRCVERSION="${EXPECTED_KVM_SRCVERSION:-0BD0A0612BCAACA2BE920F4}"
EXPECTED_KVM_INTEL_SRCVERSION="${EXPECTED_KVM_INTEL_SRCVERSION:-65E9BDBE5E3D73DEA355ECB}"
HELPERS_STARTED=0
WORKLOADS_STARTED=0

usage() {
	cat <<'EOF'
Usage:
  scripts/run_tdx_sc_fork_e2e.sh [options]

Runs only the TDX CoFunc fork E2E path from the CoFunc artifact:
  helper services -> rootfs/cgroup -> TDX CVM -> sc-snapshot -> sc-fork

Options:
  --artifact PATH          CoFunc artifact root
  --out PATH               Output directory
  --workloads LIST         Comma-separated workload/app names to run
                           Examples: fn_py_face_detection,chain_js_alexa
  --skip-build             Do not build helper/workload container images
  --keep-helpers           Leave scenv_* helper containers running
  --keep-going             Continue with later workloads after one workload fails
  --no-cleanup             Do not run best-effort artifact cleanup on exit
  --no-stop-conflicts      Do not stop known helper/CVM/OpenWhisk conflicts
  --prepare-performance    Set host CPU governor/EPP to performance before run
  --require-performance    Fail if host CPU governor/EPP is not performance
  --core-isolated          Require boot-time core isolation and pin workload there
  --isolated-cpus LIST     Like --core-isolated, but use LIST for workload affinity
  --taskset-cpus LIST      Run each workload action under taskset -c LIST
  --tdx-smp N|auto         TDX guest vCPU count; auto matches --taskset-cpus count
  --tdx-vm-cooldown SEC    Sleep after each workload so TDX/KVM state can release
  --kvm-create-vm-retries N
                           Retry workload on transient KVM_CREATE_VM EBUSY
  --kvm-create-vm-cooldown SEC
                           Cooldown before retrying KVM_CREATE_VM EBUSY
  --workload-timeout SEC   Kill a stuck workload action after SEC; 0 disables
  --quiet-workload-output  Write workload console output only to per-workload log
  -h, --help               Show this help
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

safe_name() {
	printf '%s' "$1" | tr '/,' '__'
}

cmdline_value() {
	local key=$1
	local token

	for token in $(cat /proc/cmdline); do
		case "$token" in
			"$key"=*)
				printf '%s\n' "${token#*=}"
				return
				;;
			"$key")
				printf '(set)\n'
				return
				;;
		esac
	done
	printf 'missing\n'
}

active_isolated_cpus() {
	local raw field joined
	local -a fields
	local cpus=()

	raw=$(cmdline_value isolcpus)
	[[ $raw != "missing" && $raw != "(set)" ]] || return 1
	IFS=',' read -r -a fields <<<"$raw"
	for field in "${fields[@]}"; do
		if [[ $field =~ ^[0-9]+(-[0-9]+)?$ ]]; then
			cpus+=("$field")
		fi
	done
	((${#cpus[@]})) || return 1
	joined=$(printf ',%s' "${cpus[@]}")
	printf '%s\n' "${joined#,}"
}

cpu_list_count() {
	local list=$1
	local part start end
	local count=0
	local -a parts

	list=${list//[[:space:]]/}
	[[ -n $list ]] || return 1
	IFS=',' read -r -a parts <<<"$list"
	for part in "${parts[@]}"; do
		if [[ $part =~ ^([0-9]+)-([0-9]+)$ ]]; then
			start=${BASH_REMATCH[1]}
			end=${BASH_REMATCH[2]}
			((end >= start)) || return 1
			((count += end - start + 1))
		elif [[ $part =~ ^[0-9]+$ ]]; then
			((count += 1))
		else
			return 1
		fi
	done
	printf '%s\n' "$count"
}

cmdline_key_present() {
	local key=$1
	local value

	value=$(cmdline_value "$key")
	[[ $value != "missing" ]]
}

while (($#)); do
	case "$1" in
		--artifact)
			ARTIFACT=${2:?missing value for --artifact}
			shift 2
			;;
		--out)
			OUT=${2:?missing value for --out}
			shift 2
			;;
		--workloads)
			WORKLOADS=${2:?missing value for --workloads}
			shift 2
			;;
		--skip-build)
			SKIP_BUILD=1
			shift
			;;
		--keep-helpers)
			KEEP_HELPERS=1
			shift
			;;
		--keep-going)
			KEEP_GOING=1
			shift
			;;
		--no-cleanup)
			NO_CLEANUP=1
			shift
			;;
		--no-stop-conflicts)
			STOP_CONFLICTS=0
			shift
			;;
		--prepare-performance|--performance-mode)
			PREPARE_PERFORMANCE=1
			shift
			;;
		--require-performance)
			REQUIRE_PERFORMANCE=1
			shift
			;;
		--core-isolated)
			CORE_ISOLATED=1
			shift
			;;
		--isolated-cpus)
			CORE_ISOLATED=1
			TASKSET_CPUS=${2:?missing value for --isolated-cpus}
			shift 2
			;;
		--taskset-cpus)
			TASKSET_CPUS=${2:?missing value for --taskset-cpus}
			shift 2
			;;
		--tdx-smp)
			TDX_SMP=${2:?missing value for --tdx-smp}
			shift 2
			;;
		--tdx-vm-cooldown)
			TDX_VM_COOLDOWN_SEC=${2:?missing value for --tdx-vm-cooldown}
			shift 2
			;;
		--kvm-create-vm-retries)
			KVM_CREATE_VM_BUSY_RETRIES=${2:?missing value for --kvm-create-vm-retries}
			shift 2
			;;
		--kvm-create-vm-cooldown)
			KVM_CREATE_VM_BUSY_COOLDOWN_SEC=${2:?missing value for --kvm-create-vm-cooldown}
			shift 2
			;;
		--workload-timeout)
			WORKLOAD_TIMEOUT_SEC=${2:?missing value for --workload-timeout}
			shift 2
			;;
		--quiet-workload-output)
			QUIET_WORKLOAD_OUTPUT=1
			shift
			;;
		-h|--help)
			usage
			exit 0
			;;
		*)
			die "unknown option: $1"
			;;
	esac
done

ARTIFACT=$(realpath "$ARTIFACT")
ARTIFACT_PARENT=$(dirname "$ARTIFACT")
if [[ -z $OUT ]]; then
	OUT="/home/ljhhasang/perf_proto/results/tdx_sc_fork_e2e_$(date -u +%Y%m%d_%H%M%S)"
fi
OUT=$(realpath -m "$OUT")
LOG_DIR="$OUT/log"
TRACE_ROOT="$OUT/cofunc-trace"
PARAMS_ALL="$ARTIFACT/testcases/tools/tasks/run_sc_fork/params"
PARAMS_RUN="$OUT/run_sc_fork.params"
SUMMARY_TOOL="$SCRIPT_DIR/cofunc_tdx_sc_fork_summary.py"
PERF_MODE_TOOL="$SCRIPT_DIR/cofunc_tdx_host_perf_mode.sh"

cleanup() {
	local rc=$?
	set +e
	if [[ -d ${ARTIFACT:-} ]]; then
		dmesg -T >"$OUT/dmesg-final.log" 2>/dev/null
		docker ps -a >"$OUT/docker-ps-final.log" 2>/dev/null
		screen -ls >"$OUT/screen-final.log" 2>&1
	fi
	if [[ $NO_CLEANUP == 0 && $WORKLOADS_STARTED == 1 && -d ${ARTIFACT:-} ]]; then
		log "best-effort cleanup"
		cleanup_selected_workloads "exit"
	fi
	if [[ $KEEP_HELPERS == 0 && $HELPERS_STARTED == 1 && -x ${ARTIFACT:-}/testcases/environment/shutdown_all.sh ]]; then
		"$ARTIFACT/testcases/environment/shutdown_all.sh" >"$OUT/helpers-shutdown.log" 2>&1
	fi
	exit "$rc"
}

mkdir -p "$OUT" "$LOG_DIR" "$TRACE_ROOT"
trap cleanup EXIT

[[ -d $ARTIFACT ]] || die "artifact root does not exist: $ARTIFACT"
[[ -f $PARAMS_ALL ]] || die "missing params file: $PARAMS_ALL"
[[ -x $SUMMARY_TOOL ]] || die "missing summary tool: $SUMMARY_TOOL"
[[ -x $PERF_MODE_TOOL ]] || die "missing performance mode tool: $PERF_MODE_TOOL"

if [[ -t 0 ]]; then
	sudo -v || die "sudo is required for rootfs mounts, cgroups, snapshots, and lean_container/start.sh"
else
	sudo -n true || die "sudo credentials are not cached; run 'sudo -v' in an interactive shell first"
fi

if [[ -r /sys/module/kvm_intel/parameters/tdx ]]; then
	[[ $(cat /sys/module/kvm_intel/parameters/tdx) == "Y" ]] || die "kvm_intel.tdx is not enabled"
else
	die "missing /sys/module/kvm_intel/parameters/tdx"
fi

if [[ $PREPARE_PERFORMANCE == 1 ]]; then
	log "setting host performance mode"
	"$PERF_MODE_TOOL" ensure --log "$OUT/host-performance.log"
elif [[ $REQUIRE_PERFORMANCE == 1 ]]; then
	log "checking host performance mode"
	"$PERF_MODE_TOOL" check --log "$OUT/host-performance.log" || \
		die "host performance mode is not ready; see $OUT/host-performance.log"
else
	if ! "$PERF_MODE_TOOL" check --log "$OUT/host-performance.log"; then
		log "warning: host performance mode is not fully set; use --prepare-performance for measurement runs"
	fi
fi

if [[ $CORE_ISOLATED == 1 ]]; then
	BOOT_ISOLATED_CPUS=$(active_isolated_cpus 2>/dev/null || true)
	[[ -n $BOOT_ISOLATED_CPUS ]] || \
		die "host is not booted with isolcpus; run $PERF_MODE_TOOL install-isolation, reboot, then retry"
	cmdline_key_present nohz_full || die "host is missing nohz_full boot isolation"
	cmdline_key_present rcu_nocbs || die "host is missing rcu_nocbs boot isolation"
	cmdline_key_present irqaffinity || die "host is missing irqaffinity boot isolation"
	if [[ -z $TASKSET_CPUS ]]; then
		TASKSET_CPUS=$BOOT_ISOLATED_CPUS
	fi
fi

if [[ -n $TASKSET_CPUS ]]; then
	command -v taskset >/dev/null 2>&1 || die "taskset is required for --taskset-cpus"
	taskset -c "$TASKSET_CPUS" true || die "invalid --taskset-cpus value: $TASKSET_CPUS"
fi

if [[ $TDX_SMP == "auto" ]]; then
	if [[ -n $TASKSET_CPUS ]]; then
		TDX_SMP=$(cpu_list_count "$TASKSET_CPUS") || die "cannot count CPUs in --taskset-cpus: $TASKSET_CPUS"
	else
		TDX_SMP=$(nproc)
	fi
elif ! [[ $TDX_SMP =~ ^[0-9]+$ && $TDX_SMP -gt 0 ]]; then
	die "invalid --tdx-smp value: $TDX_SMP"
fi
[[ $TDX_VM_COOLDOWN_SEC =~ ^[0-9]+$ ]] || die "invalid --tdx-vm-cooldown value: $TDX_VM_COOLDOWN_SEC"
[[ $KVM_CREATE_VM_BUSY_RETRIES =~ ^[0-9]+$ ]] || die "invalid --kvm-create-vm-retries value: $KVM_CREATE_VM_BUSY_RETRIES"
[[ $KVM_CREATE_VM_BUSY_COOLDOWN_SEC =~ ^[0-9]+$ ]] || die "invalid --kvm-create-vm-cooldown value: $KVM_CREATE_VM_BUSY_COOLDOWN_SEC"
[[ $WORKLOAD_TIMEOUT_SEC =~ ^[0-9]+$ ]] || die "invalid --workload-timeout value: $WORKLOAD_TIMEOUT_SEC"
if (( WORKLOAD_TIMEOUT_SEC > 0 )); then
	command -v timeout >/dev/null 2>&1 || die "timeout is required when --workload-timeout is nonzero"
fi

live_kvm=$(cat /sys/module/kvm/srcversion 2>/dev/null || true)
live_kvm_intel=$(cat /sys/module/kvm_intel/srcversion 2>/dev/null || true)
{
	printf 'artifact=%s\n' "$ARTIFACT"
	printf 'out=%s\n' "$OUT"
	printf 'log_dir=%s\n' "$LOG_DIR"
	printf 'kernel=%s\n' "$(uname -r)"
	printf 'kvm_srcversion=%s\n' "$live_kvm"
	printf 'kvm_intel_srcversion=%s\n' "$live_kvm_intel"
	printf 'tdx=%s\n' "$(cat /sys/module/kvm_intel/parameters/tdx)"
	printf 'prepare_performance=%s\n' "$PREPARE_PERFORMANCE"
	printf 'require_performance=%s\n' "$REQUIRE_PERFORMANCE"
	printf 'keep_going=%s\n' "$KEEP_GOING"
	printf 'core_isolated=%s\n' "$CORE_ISOLATED"
	printf 'boot_isolated_cpus=%s\n' "$BOOT_ISOLATED_CPUS"
	printf 'taskset_cpus=%s\n' "$TASKSET_CPUS"
	printf 'tdx_smp=%s\n' "$TDX_SMP"
	printf 'tdx_vm_cooldown_sec=%s\n' "$TDX_VM_COOLDOWN_SEC"
	printf 'kvm_create_vm_busy_retries=%s\n' "$KVM_CREATE_VM_BUSY_RETRIES"
	printf 'kvm_create_vm_busy_cooldown_sec=%s\n' "$KVM_CREATE_VM_BUSY_COOLDOWN_SEC"
	printf 'workload_timeout_sec=%s\n' "$WORKLOAD_TIMEOUT_SEC"
	printf 'quiet_workload_output=%s\n' "$QUIET_WORKLOAD_OUTPUT"
	printf 'kernel_cmdline=%s\n' "$(cat /proc/cmdline)"
	printf 'started_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >"$OUT/run-env.txt"

if [[ $live_kvm != "$EXPECTED_KVM_SRCVERSION" ]]; then
	log "warning: kvm srcversion is $live_kvm, expected $EXPECTED_KVM_SRCVERSION"
fi
if [[ $live_kvm_intel != "$EXPECTED_KVM_INTEL_SRCVERSION" ]]; then
	log "warning: kvm_intel srcversion is $live_kvm_intel, expected $EXPECTED_KVM_INTEL_SRCVERSION"
fi

if [[ -f "$ARTIFACT/plots/fig11.txt" ]]; then
	cp "$ARTIFACT/plots/fig11.txt" "$OUT/fig11_expected.txt"
fi
if [[ -f "$ARTIFACT/plots/finra.txt" ]]; then
	cp "$ARTIFACT/plots/finra.txt" "$OUT/finra_expected.txt"
fi

select_workloads() {
	if [[ -z $WORKLOADS ]]; then
		cp "$PARAMS_ALL" "$PARAMS_RUN"
		return
	fi

	python3 - "$PARAMS_ALL" "$PARAMS_RUN" "$WORKLOADS" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
wanted = {x.strip() for x in sys.argv[3].split(",") if x.strip()}
rows = []
for line in src.read_text().splitlines():
    if not line.strip():
        continue
    fn, times = line.split()[:2]
    base = fn.rsplit("/", 1)[-1]
    app = fn.split("/", 1)[0]
    if fn in wanted or base in wanted or app in wanted:
        rows.append(f"{fn} {times}")
missing = sorted(w for w in wanted if not any(
    line.split()[0] == w or line.split()[0].rsplit("/", 1)[-1] == w or line.split()[0].split("/", 1)[0] == w
    for line in src.read_text().splitlines() if line.strip()
))
if missing:
    raise SystemExit("unknown workload(s): " + ",".join(missing))
dst.write_text("\n".join(rows) + "\n")
PY
}

select_workloads
cp "$PARAMS_RUN" "$OUT/run_sc_fork.params.copy"

log "selected workloads"
cat "$PARAMS_RUN"
FIRST_WORKLOAD=$(awk 'NF { print $1; exit }' "$PARAMS_RUN")
[[ -n $FIRST_WORKLOAD ]] || die "no workloads selected"

check_ports_free() {
	local ports=(8080 8888 9000 9090 5984)
	local busy=0
	for port in "${ports[@]}"; do
		if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
			printf 'port %s is already listening\n' "$port" >&2
			busy=1
		fi
	done
	[[ $busy == 0 ]] || die "helper service port conflict; stop the conflicting service/container first"
}

stop_known_conflicts() {
	local names=(
		scenv_minio
		scenv_param
		scenv_file_server
		scenv_device
		scenv_couchdb
		couchdb
	)
	local name

	docker ps -a --format '{{.Names}} {{.Status}}' >"$OUT/docker-conflicts-before.log" 2>/dev/null || true
	: >"$OUT/stopped-conflicts.log"
	for name in "${names[@]}"; do
		if docker ps -a --format '{{.Names}}' | grep -Fxq "$name"; then
			log "stopping conflicting container $name"
			printf '%s\n' "$name" >>"$OUT/stopped-conflicts.log"
			docker rm -f "$name" >>"$OUT/stopped-conflicts.log" 2>&1 || true
		fi
	done
	docker ps -a --format '{{.Names}} {{.Status}}' >"$OUT/docker-conflicts-after.log" 2>/dev/null || true
}

stop_stale_artifact_cvm() {
	local session pid
	local -a stale_qemu_pids=()

	screen -ls >"$OUT/screen-cvm-before.log" 2>&1 || true
	: >"$OUT/stopped-cvm.log"

	while read -r session; do
		[[ -n ${session:-} ]] || continue
		log "stopping stale artifact screen $session"
		printf 'screen %s\n' "$session" >>"$OUT/stopped-cvm.log"
		screen -S "$session" -X quit >>"$OUT/stopped-cvm.log" 2>&1 || true
	done < <({ screen -ls 2>/dev/null || true; } | awk '/split-container-(cvm|snapshot)-/ { print $1 }')

	mapfile -t stale_qemu_pids < <(
		{ pgrep -af qemu-system-x86_64 2>/dev/null || true; } |
			awk -v root="$ARTIFACT_PARENT" 'index($0, root) { print $1 }'
	)
	if ((${#stale_qemu_pids[@]})); then
		printf 'qemu pids %s\n' "${stale_qemu_pids[*]}" >>"$OUT/stopped-cvm.log"
		kill "${stale_qemu_pids[@]}" >>"$OUT/stopped-cvm.log" 2>&1 || \
			sudo -n kill "${stale_qemu_pids[@]}" >>"$OUT/stopped-cvm.log" 2>&1 || true
		sleep 2
		for pid in "${stale_qemu_pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null || sudo -n kill -0 "$pid" 2>/dev/null; then
				printf 'force killing qemu pid %s\n' "$pid" >>"$OUT/stopped-cvm.log"
				kill -9 "$pid" >>"$OUT/stopped-cvm.log" 2>&1 || \
					sudo -n kill -9 "$pid" >>"$OUT/stopped-cvm.log" 2>&1 || true
			fi
		done
	fi

	screen -ls >"$OUT/screen-cvm-after.log" 2>&1 || true
	{ pgrep -af qemu-system-x86_64 2>/dev/null || true; } >"$OUT/qemu-after-conflict-stop.log"
}

artifact_qemu_pids() {
	{ pgrep -af qemu-system-x86_64 2>/dev/null || true; } |
		awk -v root="$ARTIFACT_PARENT" 'index($0, root) { print $1 }'
}

wait_for_no_artifact_qemu() {
	local timeout=${1:-30}
	local start now pids

	start=$(date +%s)
	while true; do
		pids=$(artifact_qemu_pids | xargs echo)
		if [[ -z $pids ]]; then
			return 0
		fi
		now=$(date +%s)
		if (( now - start >= timeout )); then
			printf 'timed out waiting for artifact qemu exit; pids=%s\n' "$pids" >>"$OUT/artifact-clean.log"
			return 1
		fi
		sleep 1
	done
}

cleanup_tdx_vm_runtime() {
	local reason=$1

	printf 'tdx runtime cleanup reason: %s\n' "$reason" >>"$OUT/artifact-clean.log"
	SLOT_ID=0 "$ARTIFACT/testcases/tools/sc-snapshot.sh" clean >>"$OUT/artifact-clean.log" 2>&1 || true
	"$ARTIFACT/testcases/tools/cvm.sh" clean >>"$OUT/artifact-clean.log" 2>&1 || true
	wait_for_no_artifact_qemu 30 || true
}

tdx_vm_cooldown() {
	local reason=$1

	wait_for_no_artifact_qemu 30 || true
	if (( TDX_VM_COOLDOWN_SEC > 0 )); then
		printf 'tdx vm cooldown %ss after %s\n' "$TDX_VM_COOLDOWN_SEC" "$reason" >>"$OUT/artifact-clean.log"
		sleep "$TDX_VM_COOLDOWN_SEC"
	fi
}

wait_for_ready() {
	local name=$1
	local timeout=$2
	shift 2
	local start now

	start=$(date +%s)
	while true; do
		if "$@" >>"$OUT/helpers-ready.log" 2>&1; then
			printf '%s ready\n' "$name" >>"$OUT/helpers-ready.log"
			return 0
		fi
		now=$(date +%s)
		if (( now - start >= timeout )); then
			printf '%s not ready after %ss: %s\n' "$name" "$timeout" "$*" >>"$OUT/helpers-ready.log"
			return 1
		fi
		sleep 1
	done
}

check_param_ready() {
	local workload=$FIRST_WORKLOAD
	local param_name=$workload

	if [[ $param_name != testcases/* ]]; then
		param_name="testcases/$param_name"
	fi

	curl -fsS -X POST http://127.0.0.1:8888/get_param \
		--data-urlencode "fn_name=$param_name" -o /dev/null
}

check_helpers_ready() {
	local fail=0
	: >"$OUT/helpers-ready.log"

	wait_for_ready "minio" 60 \
		curl -fsS http://127.0.0.1:9000/minio/health/ready -o /dev/null || fail=1
	wait_for_ready "param" 60 check_param_ready || fail=1
	wait_for_ready "file_server" 60 \
		curl -fsS http://127.0.0.1:8080/yfinance.csv -o /dev/null || fail=1
	wait_for_ready "device" 60 \
		curl -fsS http://127.0.0.1:9090/ -o /dev/null || fail=1
	wait_for_ready "couchdb" 90 \
		curl -fsS http://admin:password@127.0.0.1:5984/ -o /dev/null || fail=1

	if [[ $fail != 0 ]]; then
		docker ps -a >"$OUT/docker-ps-helper-ready-failed.log" 2>/dev/null || true
		for helper in scenv_minio scenv_param scenv_file_server scenv_device scenv_couchdb; do
			docker logs --tail 120 "$helper" >"$OUT/${helper}.ready-failed.log" 2>&1 || true
		done
		die "helper readiness check failed; see $OUT/helpers-ready.log"
	fi
}

cleanup_selected_workloads() {
	local reason=$1
	local fn_name times fn_dir

	printf 'cleanup reason: %s\n' "$reason" >>"$OUT/artifact-clean.log"
	cleanup_tdx_vm_runtime "$reason"

	while read -r fn_name times; do
		[[ -n ${fn_name:-} ]] || continue
		fn_dir="$ARTIFACT/testcases/testcases/$fn_name"
		[[ -d $fn_dir ]] || continue
		{
			printf '== clean %s ==\n' "$fn_name"
			(
				cd "$fn_dir"
				"$ARTIFACT/testcases/tools/lean_container/rootfs.sh" clean || true
				"$ARTIFACT/testcases/tools/lean_container/cgroup.sh" clean || true
				"$ARTIFACT/testcases/tools/hugepage.sh" clean || true
			)
		} >>"$OUT/artifact-clean.log" 2>&1
	done <"$PARAMS_RUN"
}

copy_workload_debug_logs() {
	local fn_name=$1
	local suffix=$2
	local fn_dir safe

	fn_dir="$ARTIFACT/testcases/testcases/$fn_name"
	safe=$(safe_name "$fn_name")
	if [[ -f $fn_dir/exec_log ]]; then
		cp "$fn_dir/exec_log" "$OUT/workload-${safe}-exec_log${suffix}.log" 2>/dev/null || true
	fi
}

run_workload_action() {
	local fn_name=$1
	local times=$2
	local run_log=$3
	local rc
	local -a action_cmd

	action_cmd=(./testcases/tools/tasks/run_sc_fork/action.sh "$fn_name" "$times")
	if [[ -n $TASKSET_CPUS ]]; then
		action_cmd=(taskset -c "$TASKSET_CPUS" "${action_cmd[@]}")
	fi
	if (( WORKLOAD_TIMEOUT_SEC > 0 )); then
		action_cmd=(timeout --kill-after=30s "$WORKLOAD_TIMEOUT_SEC" "${action_cmd[@]}")
	fi

	set +e
	if [[ $QUIET_WORKLOAD_OUTPUT == 1 ]]; then
		(
			cd "$ARTIFACT"
			export LOG_DIR
			export COFUNC_TRACE_ROOT="$TRACE_ROOT"
			export COFUNC_TDX_SMP="$TDX_SMP"
			export HOST_IP
			export CNTR_IP
			"${action_cmd[@]}"
		) >"$run_log" 2>&1
		rc=$?
	else
		(
			cd "$ARTIFACT"
			export LOG_DIR
			export COFUNC_TRACE_ROOT="$TRACE_ROOT"
			export COFUNC_TDX_SMP="$TDX_SMP"
			export HOST_IP
			export CNTR_IP
			"${action_cmd[@]}"
		) 2>&1 | tee "$run_log"
		rc=${PIPESTATUS[0]}
	fi
	if (( WORKLOAD_TIMEOUT_SEC > 0 )) && [[ $rc == 124 || $rc == 137 ]]; then
		printf 'workload action timed out after %ss; rc=%s\n' "$WORKLOAD_TIMEOUT_SEC" "$rc" >>"$run_log"
	fi
	set -e
	return "$rc"
}

is_kvm_create_vm_busy() {
	local run_log=$1

	rg -q 'KVM_CREATE_VM.*Device or resource busy|failed to initialize kvm: Device or resource busy' "$run_log"
}

build_selected_workloads() {
	local fn_name times fn_dir

	: >"$OUT/build-workloads.log"
	while read -r fn_name times; do
		[[ -n ${fn_name:-} ]] || continue
		fn_dir="$ARTIFACT/testcases/testcases/$fn_name"
		[[ -d $fn_dir ]] || die "missing workload directory: $fn_dir"
		log "building workload image $fn_name"
		{
			printf '== %s ==\n' "$fn_name"
			(
				cd "$fn_dir"
				if git -C "$ARTIFACT" ls-files --error-unmatch "testcases/testcases/$fn_name/tools" >/dev/null 2>&1; then
					printf 'refusing to remove tracked workload tools directory for %s\n' "$fn_name" >&2
					exit 1
				fi
				cleanup_workload_tools() {
					rm -rf "$fn_dir/tools"
				}
				trap cleanup_workload_tools EXIT INT TERM
				cleanup_workload_tools
				# TDX sc_fork only needs the Docker image and lean-container rootfs state.
				# The artifact's generic build task also cleans SeveriFast /mnt state,
				# which is unrelated here and breaks when the artifact is under /mnt/nvme_500g.
				"$ARTIFACT/testcases/tools/lean_container/rootfs.sh" clean
				"$ARTIFACT/testcases/tools/build.sh"
				cleanup_workload_tools
			)
		} >>"$OUT/build-workloads.log" 2>&1
	done <"$PARAMS_RUN"
}

log "stopping old artifact helpers"
"$ARTIFACT/testcases/environment/shutdown_all.sh" >"$OUT/helpers-pre-shutdown.log" 2>&1 || true
if [[ $STOP_CONFLICTS == 1 ]]; then
	stop_known_conflicts
	stop_stale_artifact_cvm
else
	log "not stopping known conflicts because --no-stop-conflicts was set"
fi
check_ports_free
log "cleaning selected workload state"
cleanup_selected_workloads "pre-run"

if [[ $SKIP_BUILD == 0 ]]; then
	log "building helper images"
	(
		cd "$ARTIFACT/testcases/environment"
		./build_all.sh
	) >"$OUT/build-helpers.log" 2>&1

	log "ensuring helper base images"
	docker image inspect minio/minio >/dev/null 2>&1 || docker pull minio/minio
	docker image inspect couchdb >/dev/null 2>&1 || docker pull couchdb

	log "building workload images"
	build_selected_workloads
else
	log "skipping image builds"
fi

log "starting artifact helpers"
(
	cd "$ARTIFACT"
	./testcases/environment/start_all.sh
) >"$OUT/helpers-start.log" 2>&1
HELPERS_STARTED=1
docker ps >"$OUT/docker-ps-after-helpers.log"
log "checking helper readiness"
check_helpers_ready

export LOG_DIR
export COFUNC_TRACE_ROOT="$TRACE_ROOT"
export HOST_IP
export CNTR_IP
HOST_IP=$(jq -r ".host_ip" "$ARTIFACT/config.json")
CNTR_IP=$(jq -r ".cntr_ip" "$ARTIFACT/config.json")

dmesg -T >"$OUT/dmesg-before.log" 2>/dev/null || true

log "running TDX CoFunc fork workloads"
WORKLOADS_STARTED=1
status_file="$OUT/workload-status.tsv"
printf 'workload\tstatus\tattempts\trc\tlog\n' >"$status_file"
while read -r fn_name times; do
	[[ -n ${fn_name:-} ]] || continue
	run_log="$OUT/workload-$(safe_name "$fn_name").log"
	attempt=1
	while true; do
		if (( attempt == 1 )); then
			log "run $fn_name x$times"
		else
			log "retry $fn_name x$times attempt $attempt"
		fi
		if run_workload_action "$fn_name" "$times" "$run_log"; then
			printf '%s\tok\t%s\t0\t%s\n' "$fn_name" "$attempt" "$run_log" >>"$status_file"
			tdx_vm_cooldown "$fn_name"
			break
		fi
		rc=$?
		if is_kvm_create_vm_busy "$run_log" && (( attempt <= KVM_CREATE_VM_BUSY_RETRIES )); then
			log "KVM_CREATE_VM busy for $fn_name; cleanup and retry after ${KVM_CREATE_VM_BUSY_COOLDOWN_SEC}s"
			cp "$run_log" "$run_log.attempt-$attempt.kvm-create-vm-busy" 2>/dev/null || true
			copy_workload_debug_logs "$fn_name" ".attempt-$attempt.kvm-create-vm-busy"
			cleanup_tdx_vm_runtime "kvm-create-vm-busy-$fn_name-attempt-$attempt"
			sleep "$KVM_CREATE_VM_BUSY_COOLDOWN_SEC"
			((attempt += 1))
			continue
		fi
		copy_workload_debug_logs "$fn_name" ".failure"
		printf '%s\tfailed\t%s\t%s\t%s\n' "$fn_name" "$attempt" "$rc" "$run_log" >>"$status_file"
		if [[ $KEEP_GOING == 1 ]]; then
			log "workload failed: $fn_name; continuing because --keep-going is set"
			cleanup_tdx_vm_runtime "failed-$fn_name"
			tdx_vm_cooldown "failed-$fn_name"
			break
		fi
		die "workload failed: $fn_name; see $run_log"
	done
done <"$PARAMS_RUN"

log "validating result logs"
validation="$OUT/validation.txt"
: >"$validation"
fail=0
while read -r fn_name times; do
	[[ -n ${fn_name:-} ]] || continue
	result_log="$LOG_DIR/$fn_name/sc_fork.log"
	if [[ ! -f $result_log ]]; then
		printf 'missing %s\n' "$result_log" | tee -a "$validation"
		fail=1
		continue
	fi
	actual=$(grep -c '^{' "$result_log" || true)
	if [[ $actual != "$times" ]]; then
		printf 'bad sample count %s expected=%s actual=%s\n' "$result_log" "$times" "$actual" | tee -a "$validation"
		fail=1
	fi
	if rg -n 'Traceback|HTTP Error|Connection refused|Bad address|prefault skipped|Invalid SPTE|kernel BUG|Oops' "$result_log" >>"$validation"; then
		fail=1
	fi
done <"$PARAMS_RUN"

dmesg -T >"$OUT/dmesg-after.log" 2>/dev/null || true
if rg -i 'Invalid SPTE|kernel BUG|BUG:|Oops|Bad address|prefault skipped' "$OUT/dmesg-after.log" >"$OUT/dmesg-kvm-errors.log"; then
	fail=1
else
	: >"$OUT/dmesg-kvm-errors.log"
fi

log "summarizing"
"$SUMMARY_TOOL" "$LOG_DIR" --expected "$OUT/fig11_expected.txt" | tee "$OUT/tdx_sc_fork_summary.txt"

if [[ $fail != 0 ]]; then
	die "run completed with validation failures; see $validation and $OUT/dmesg-kvm-errors.log"
fi

log "done: $OUT"
