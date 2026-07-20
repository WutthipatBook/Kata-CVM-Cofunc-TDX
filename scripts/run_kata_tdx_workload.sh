#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact}
LOG_DIR=${LOG_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_manual_$(date -u +%Y%m%d_%H%M%S)/log}
KATA_RUNTIME_NAME=${KATA_RUNTIME_NAME:-kata-qemu-tdx}
KATA_RUNTIME_TYPE=${KATA_RUNTIME_TYPE:-io.containerd.${KATA_RUNTIME_NAME}.v2}
KATA_CONFIG=${KATA_CONFIG:-/etc/kata-containers/configuration-qemu-tdx.toml}
CONTAINERD_NS=${CONTAINERD_NS:-default}
CONTAINERD_SNAPSHOTTER=${CONTAINERD_SNAPSHOTTER:-}
CONTAINERD_PLATFORM=${CONTAINERD_PLATFORM:-linux/amd64}
CONTAINERD_NETWORK_MODE=${CONTAINERD_NETWORK_MODE:-none}
WORKLOAD=${1:-fn_py_face_detection}
TIMES=${2:-1}
DEBUG_COLLECTOR=${DEBUG_COLLECTOR:-/home/booklyn/cofunc-tdx/scripts/collect_kata_tdx_debug.sh}
COFUNC_DOCKER_TTY=${COFUNC_DOCKER_TTY:-0}
REWRITE_LOOPBACK=${REWRITE_LOOPBACK:-1}
RUN_PREPARE_AS_USER=${RUN_PREPARE_AS_USER:-1}
AUTO_START_HELPERS=${AUTO_START_HELPERS:-1}
KATA_RUN_TIMEOUT=${KATA_RUN_TIMEOUT:-180}
RUN_LOG=${RUN_LOG:-${LOG_DIR%/log}/runner.log}
KATA_QEMU_WRAPPER_LOG=${KATA_QEMU_WRAPPER_LOG:-}
KATA_PRE_COMMAND_DELAY=${KATA_PRE_COMMAND_DELAY:-0}

mkdir -p "$(dirname "$RUN_LOG")"
exec > >(tee -a "$RUN_LOG") 2>&1

echo "run_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "workload=$WORKLOAD times=$TIMES"
echo "log_dir=$LOG_DIR"
echo "kata_runtime_type=$KATA_RUNTIME_TYPE"
echo "kata_config=$KATA_CONFIG"
echo "containerd_snapshotter=${CONTAINERD_SNAPSHOTTER:-default}"
echo "containerd_network_mode=$CONTAINERD_NETWORK_MODE"
echo "kata_run_timeout=$KATA_RUN_TIMEOUT"
echo "kata_pre_command_delay=$KATA_PRE_COMMAND_DELAY"

case "$KATA_PRE_COMMAND_DELAY" in
    ''|*[!0-9]*)
        echo "KATA_PRE_COMMAND_DELAY must be a non-negative whole number of seconds" >&2
        exit 2
        ;;
esac

need_sudo() {
    if (( EUID == 0 )); then
        SUDO=()
        return
    fi
    SUDO=(sudo)
    if ! sudo -n true 2>/dev/null; then
        cat >&2 <<'EOF'
sudo credentials are not cached.
Run `sudo -v` in a terminal, then rerun this script.
EOF
        exit 1
    fi
}

need_sudo
[[ -r "$KATA_CONFIG" ]] || { echo "missing Kata config: $KATA_CONFIG" >&2; exit 1; }

if [[ -n "$CONTAINERD_SNAPSHOTTER" ]]; then
    snapshotter_status=$("${SUDO[@]}" ctr plugins ls | awk \
        -v snapshotter="$CONTAINERD_SNAPSHOTTER" \
        '$1 == "io.containerd.snapshotter.v1" && $2 == snapshotter { print $4 }')
    [[ "$snapshotter_status" == ok ]] || {
        echo "containerd snapshotter is not ready: ${CONTAINERD_SNAPSHOTTER} (${snapshotter_status:-missing})" >&2
        exit 1
    }
fi

run_prepare() {
    if [[ ! -f prepare.py ]]; then
        return
    fi

    if [[ "$RUN_PREPARE_AS_USER" == "1" && $EUID == 0 && -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
        local prepare_home
        prepare_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        runuser -u "$SUDO_USER" -- env \
            HOME="$prepare_home" \
            USER="$SUDO_USER" \
            LOGNAME="$SUDO_USER" \
            PATH="$PATH" \
            ./prepare.py
    else
        ./prepare.py
    fi
}

wait_for_ready() {
    local name=$1
    local timeout=$2
    shift 2
    local start now

    start=$(date +%s)
    while true; do
        if "$@" >/dev/null 2>&1; then
            return
        fi
        now=$(date +%s)
        if (( now - start >= timeout )); then
            echo "timed out waiting for $name" >&2
            return 1
        fi
        sleep 1
    done
}

check_minio_ready() {
    curl -fsS http://127.0.0.1:9000/minio/health/ready >/dev/null
}

check_param_ready() {
    local param_name="testcases/$WORKLOAD"
    curl -fsS -X POST http://127.0.0.1:8888/get_param \
        --data-urlencode "fn_name=$param_name" >/dev/null
}

ensure_artifact_helpers() {
    if [[ "$AUTO_START_HELPERS" != "1" ]]; then
        return
    fi

    local helper_log_dir="$LOG_DIR/_helpers"
    mkdir -p "$helper_log_dir"

    if ! check_minio_ready; then
        "${SUDO[@]}" docker rm -f scenv_minio >"$helper_log_dir/minio-rm.log" 2>&1 || true
        "${SUDO[@]}" docker image inspect minio/minio >/dev/null 2>&1 || \
            "${SUDO[@]}" docker pull minio/minio >"$helper_log_dir/minio-pull.log" 2>&1
        "${SUDO[@]}" docker run -d --rm --name scenv_minio \
            --net=host \
            -e "MINIO_ROOT_USER=root" \
            -e "MINIO_ROOT_PASSWORD=password" \
            minio/minio server /data >"$helper_log_dir/minio-start.log" 2>&1
    fi
    wait_for_ready "minio" 60 check_minio_ready

    if ! check_param_ready; then
        "${SUDO[@]}" docker rm -f scenv_param >"$helper_log_dir/param-rm.log" 2>&1 || true
        if ! "${SUDO[@]}" docker image inspect scenv_param >/dev/null 2>&1; then
            (
                cd "$ARTIFACT_DIR/testcases/environment/parameter"
                "${SUDO[@]}" docker build -t scenv_param .
            ) >"$helper_log_dir/param-build.log" 2>&1
        fi
        "${SUDO[@]}" docker run -d --rm --name scenv_param \
            --net=host \
            -v "$ARTIFACT_DIR/testcases:/testcases" \
            scenv_param >"$helper_log_dir/param-start.log" 2>&1
    fi
    wait_for_ready "parameter" 60 check_param_ready
}

cleanup_kata_container() {
    local container_id=$1
    "${SUDO[@]}" ctr -n "$CONTAINERD_NS" tasks kill "$container_id" >/dev/null 2>&1 || true
    "${SUDO[@]}" ctr -n "$CONTAINERD_NS" tasks rm -f "$container_id" >/dev/null 2>&1 || true
    "${SUDO[@]}" ctr -n "$CONTAINERD_NS" containers rm "$container_id" >/dev/null 2>&1 || true
}

cleanup_temp_files() {
    local path
    for path in "${image_archive:-}" "${dockerfile:-}"; do
        [[ -n "$path" ]] || continue
        rm -f "$path" 2>/dev/null || "${SUDO[@]}" rm -f "$path" 2>/dev/null || true
    done
}

collect_qemu_wrapper_logs() {
    local dst="$LOG_DIR/_helpers/qemu-wrapper-logs"
    local path

    mkdir -p "$dst"
    for path in \
        /tmp/kata-qemu-tdx-oldabi-wrapper*.log \
        /tmp/kata-qemu-tdx-oldabi-qemu*.log \
        /tmp/kata-qemu-tdx-oldabi-serial*.log \
        /tmp/kata-qemu-tdx-oldabi-debugcon*.log \
        /tmp/kata-qemu-tdx-oldabi-trace*.log; do
        [[ -f "$path" ]] || continue
        cp "$path" "$dst/$(basename "$path")" 2>/dev/null || true
    done
}

collect_failure_debug() {
    local container_id=$1
    local iter=$2
    local since=$3
    local safe_workload=${WORKLOAD//\//_}
    local dst="$LOG_DIR/_helpers/debug-after-failure-${safe_workload}-${iter}-${container_id}"

    [[ -x "$DEBUG_COLLECTOR" ]] || return
    OUT="$dst" \
        SINCE="$since" \
        KATA_CONFIG="$KATA_CONFIG" \
        KATA_QEMU_WRAPPER_LOG="$KATA_QEMU_WRAPPER_LOG" \
        "$DEBUG_COLLECTOR" >"$LOG_DIR/_helpers/debug-after-failure-${safe_workload}-${iter}.log" 2>&1 || true
}

tools="$ARTIFACT_DIR/testcases/tools"
case "$WORKLOAD" in
    /*|*../*) echo "invalid workload path: $WORKLOAD" >&2; exit 2 ;;
esac

workload_dir="$ARTIFACT_DIR/testcases/testcases/$WORKLOAD"
[[ -d "$workload_dir" ]] || { echo "missing workload: $workload_dir" >&2; exit 1; }

export CNTR_IP=${CNTR_IP:-$(jq -r ".cntr_ip" "$ARTIFACT_DIR/config.json")}
export HOST_IP=${HOST_IP:-$(jq -r ".host_ip" "$ARTIFACT_DIR/config.json")}
export KATA_HOST_IP=${KATA_HOST_IP:-$HOST_IP}

pushd "$workload_dir" >/dev/null
fn_name=$(basename "$PWD")
command=$(cat command)
log_dir="$LOG_DIR/$WORKLOAD"
log_file="$log_dir/kata_launch.log"
dockerfile=""
image_archive=""
mkdir -p "$log_dir"
rm -f "$log_file"

ensure_artifact_helpers
run_prepare

if ! "${SUDO[@]}" docker image inspect "$fn_name:latest" >/dev/null 2>&1; then
    "$tools/build.sh"
fi

image_to_run="$fn_name:latest"
if [[ "$REWRITE_LOOPBACK" == "1" ]]; then
    image_to_run="kata-tdx-${fn_name}:latest"
    dockerfile=$(mktemp)
    trap cleanup_temp_files EXIT
    cat > "$dockerfile" <<EOF
ARG BASE_IMAGE
FROM \${BASE_IMAGE}
RUN find /func -type f \( -name '*.py' -o -name '*.js' \) -print0 | xargs -0 -r sed -i 's#127\\.0\\.0\\.1#${KATA_HOST_IP}#g'
EOF
    "${SUDO[@]}" docker build \
        --build-arg "BASE_IMAGE=$fn_name:latest" \
        -t "$image_to_run" \
        -f "$dockerfile" /tmp >/dev/null
fi

"${SUDO[@]}" docker image inspect "$image_to_run" \
    --format 'image_id={{.Id}} image_size_bytes={{.Size}} image_layer_count={{len .RootFS.Layers}}'

image_archive=$(mktemp --suffix ".${fn_name}.docker.tar")
trap cleanup_temp_files EXIT
"${SUDO[@]}" docker save -o "$image_archive" "$image_to_run"

image_import_args=(--all-platforms)
run_snapshotter_args=()
if [[ -n "$CONTAINERD_SNAPSHOTTER" ]]; then
    image_import_args=(
        --local
        --platform "$CONTAINERD_PLATFORM"
        --snapshotter "$CONTAINERD_SNAPSHOTTER"
    )
    run_snapshotter_args=(--snapshotter "$CONTAINERD_SNAPSHOTTER")
fi

run_network_args=()
case "$CONTAINERD_NETWORK_MODE" in
    none)
        ;;
    cni)
        run_network_args=(--cni)
        ;;
    host)
        run_network_args=(--net-host)
        ;;
    *)
        echo "invalid CONTAINERD_NETWORK_MODE: $CONTAINERD_NETWORK_MODE (expected none, cni, or host)" >&2
        exit 2
        ;;
esac
"${SUDO[@]}" ctr -n "$CONTAINERD_NS" images import \
    "${image_import_args[@]}" "$image_archive" >/dev/null

image_ref="$image_to_run"
if ! "${SUDO[@]}" ctr -n "$CONTAINERD_NS" images ls -q | rg -qx "$image_ref"; then
    image_ref="docker.io/library/${image_to_run}"
fi

for i in $(seq "$TIMES"); do
    container_id="kata-tdx-${fn_name}-${i}-$$"
    exec_log=exec_log
    rm -f "$exec_log"
    echo "mode kata-launch" > "$exec_log"
    launch_since=$(date -u "+%Y-%m-%d %H:%M:%S")
    printf "t_launch_begin %s\n" "$(date +%s.%7N)" | tee -a "$exec_log"
    echo "launching Kata-TDX container_id=$container_id image=$image_ref timeout=${KATA_RUN_TIMEOUT}s" >&2

    guest_command="printf 't_import_begin %s\\n' \$(date +%s.%7N); exec $command"
    if (( KATA_PRE_COMMAND_DELAY > 0 )); then
        guest_command="printf 't_network_wait_begin %s\\n' \$(date +%s.%7N); sleep $KATA_PRE_COMMAND_DELAY; printf 't_network_wait_done %s\\n' \$(date +%s.%7N); $guest_command"
    fi

    set +e
    timeout --foreground --kill-after=30s "$KATA_RUN_TIMEOUT" \
        "${SUDO[@]}" ctr -n "$CONTAINERD_NS" run --rm \
            "${run_snapshotter_args[@]}" \
            --runtime "$KATA_RUNTIME_TYPE" \
            --runtime-config-path "$KATA_CONFIG" \
            "${run_network_args[@]}" \
            "$image_ref" "$container_id" \
            sh -lc "$guest_command" | tee -a "$exec_log"
    rc=${PIPESTATUS[0]}
    set -e

    if (( rc != 0 )); then
        collect_qemu_wrapper_logs
        collect_failure_debug "$container_id" "$i" "$launch_since"
        if (( rc == 124 )); then
            echo "Kata-TDX workload timed out after ${KATA_RUN_TIMEOUT}s: workload=$WORKLOAD iter=$i" >&2
        fi
        cleanup_kata_container "$container_id"
        echo "Kata-TDX workload failed: workload=$WORKLOAD iter=$i rc=$rc" >&2
        exit "$rc"
    fi

    "$tools/analyze.py" --log "$log_file"
done

popd >/dev/null
echo "$log_file"
