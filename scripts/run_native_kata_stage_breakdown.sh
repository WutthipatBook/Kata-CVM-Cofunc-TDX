#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_DIR=${ARTIFACT_DIR:-/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact}
OUT_ROOT=${OUT_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns}
SCOPE=${1:-fig11}
RUN_NAME=${RUN_NAME:-native_kata_stage_${SCOPE}_$(date -u +%Y%m%d_%H%M%S)}
RUN_DIR=${RUN_DIR:-$OUT_ROOT/$RUN_NAME}
LOG_DIR=$RUN_DIR/log
INCLUDE_KATA_DNA=${INCLUDE_KATA_DNA:-0}
ALLOW_SC_LAUNCH_FAIL=${ALLOW_SC_LAUNCH_FAIL:-1}
ALLOW_KATA_FAIL=${ALLOW_KATA_FAIL:-0}
RUN_NATIVE=${RUN_NATIVE:-1}
RUN_SC_LAUNCH=${RUN_SC_LAUNCH:-1}
RUN_KATA=${RUN_KATA:-1}

case "$SCOPE" in
    face|fig11) ;;
    *)
        echo "usage: $0 [face|fig11]" >&2
        exit 2
        ;;
esac

mkdir -p "$LOG_DIR"
exec > >(tee -a "$RUN_DIR/runner.log") 2>&1

cd "$ARTIFACT_DIR"

export CNTR_IP=${CNTR_IP:-$(jq -r ".cntr_ip" config.json)}
export HOST_IP=${HOST_IP:-$(jq -r ".host_ip" config.json)}
export LOG_DIR
export COFUNC_DOCKER_TTY=${COFUNC_DOCKER_TTY:-0}
export COFUNC_TRACE_ROOT=${COFUNC_TRACE_ROOT:-$RUN_DIR/cofunc-trace}
export COFUNC_TDX_QEMU=${COFUNC_TDX_QEMU:-/mnt/new_disk/cofunc_tdx_artifact/install/qemu-tdx-2022-09-01-cofunc/bin/qemu-system-x86_64}
export COFUNC_TDX_OVMF=${COFUNC_TDX_OVMF:-/mnt/new_disk/cofunc_tdx_artifact/firmware/ovmf-inteltdx_2025.02-8ubuntu3.1/usr/share/ovmf/OVMF.inteltdx.fd}

TASK_DIR=testcases/tools/tasks
TOOLS_DIR=testcases/tools

if ! sudo -n true 2>/dev/null; then
    cat >&2 <<'EOF'
sudo credentials are not cached.
Run `sudo -v` in a terminal, then rerun this script.
EOF
    exit 1
fi

if [[ "$SCOPE" == "face" ]]; then
    native_fork_params=(
        "fn_py_face_detection 5"
    )
    native_launch_params=(
        "fn_py_face_detection 5"
    )
    kata_params=(
        "fn_py_face_detection 5"
    )
    sc_launch_params=(
        "fn_py_face_detection 5"
    )
else
    native_fork_params=(
        "fn_py_face_detection 20"
        "fn_py_image_processing 20"
        "fn_py_sentiment 20"
        "fn_py_video_processing 5"
        "fn_py_compression 20"
        "fn_py_dna_visualisation 10"
    )
    native_launch_params=(
        "fn_js_uploader 20"
        "fn_js_thumbnailer 20"
        "chain_js_alexa/fn_js_alexa_frontend 20"
        "chain_js_alexa/fn_js_alexa_interact 20"
        "chain_js_alexa/fn_js_alexa_smarthome 20"
        "chain_js_alexa/fn_js_alexa_tv 20"
    )
    kata_params=(
        "fn_py_face_detection 20"
        "fn_py_image_processing 20"
        "fn_py_sentiment 20"
        "fn_py_video_processing 5"
        "fn_py_compression 20"
        "fn_js_uploader 20"
        "fn_js_thumbnailer 20"
        "chain_js_alexa/fn_js_alexa_frontend 20"
        "chain_js_alexa/fn_js_alexa_interact 20"
        "chain_js_alexa/fn_js_alexa_smarthome 20"
        "chain_js_alexa/fn_js_alexa_tv 20"
    )
    if [[ "$INCLUDE_KATA_DNA" == "1" ]]; then
        kata_params+=("fn_py_dna_visualisation 10")
    fi
    sc_launch_params=("${kata_params[@]}")
fi

declare -A workloads=()
for entry in "${native_fork_params[@]}" "${native_launch_params[@]}" "${kata_params[@]}" "${sc_launch_params[@]}"; do
    workloads["${entry%% *}"]=1
done

run_action_list() {
    local task=$1
    shift
    local entries=("$@")
    local prepare="$TASK_DIR/$task/prepare.sh"
    local cleanup="$TASK_DIR/$task/cleanup.sh"
    local action="$TASK_DIR/$task/action.sh"
    local rc=0

    echo
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) $task prepare ==="
    [[ ! -x "$prepare" ]] || "$prepare"

    for entry in "${entries[@]}"; do
        echo
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) $task $entry ==="
        # Intentional word splitting: params are "workload samples".
        set +e
        "$action" $entry
        rc=$?
        set -e
        if (( rc != 0 )); then
            break
        fi
    done

    echo
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) $task cleanup ==="
    [[ ! -x "$cleanup" ]] || "$cleanup"
    return "$rc"
}

clean_firecracker_rootfs() {
    while findmnt -rn /mnt >/dev/null; do
        sudo umount /mnt
    done
    rm -rf .fc-rootfs
    mkdir .fc-rootfs
}

rebuild_workload() {
    local workload=$1

    pushd "testcases/testcases/$workload"
    "$ARTIFACT_DIR/$TOOLS_DIR/lean_container/rootfs.sh" clean
    clean_firecracker_rootfs
    "$ARTIFACT_DIR/$TOOLS_DIR/build.sh"
    popd
}

build_kata_rootfs() {
    local fn_name
    local command
    local rootfs
    local init

    fn_name=$(basename "$(pwd)")
    command=$(cat command)
    rootfs=.fc-rootfs/rootfs.ext4

    clean_firecracker_rootfs
    fallocate -l 1G "$rootfs"
    mkfs.ext4 "$rootfs"
    sudo mount "$rootfs" /mnt

    docker rm -f "$fn_name" &>/dev/null || true
    docker create --name "$fn_name" "$fn_name"
    docker export "$fn_name" | sudo tar -C /mnt -xf -
    docker rm -f "$fn_name"

    set +o pipefail
    rg -l "127.0.0.1" /mnt/func | sudo xargs -r perl -pi -E "s/127.0.0.1/$HOST_IP/g"
    set -o pipefail

    init=/mnt/bin/myinit
    echo "#!/bin/sh" | sudo tee "$init"
    echo "mount -t sysfs sysfs /sys" | sudo tee -a "$init"
    echo "mount -t proc proc /proc" | sudo tee -a "$init"
    echo "mount -t tmpfs tmpfs /tmp" | sudo tee -a "$init"
    echo "ip addr add dev eth0 \${myip}" | sudo tee -a "$init"
    echo "ip link set eth0 up" | sudo tee -a "$init"
    echo "printf \"t_import_begin %s\\n\" \$(date +%s.%7N)" | sudo tee -a "$init"
    echo "$command" | sudo tee -a "$init"
    sudo chmod +x "$init"

    sudo umount /mnt
}

run_kata_list() {
    local entries=("$@")
    local rc=0

    echo
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) run_severifast_launch prepare ==="
    "$TASK_DIR/run_severifast_launch/prepare.sh"

    for entry in "${entries[@]}"; do
        local workload="${entry%% *}"
        local times="${entry##* }"
        local log_dir="$LOG_DIR/$workload"
        local log_file="$log_dir/kata_launch.log"

        echo
        echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) run_severifast_launch $entry ==="
        pushd "testcases/testcases/$workload"
        mkdir -p "$log_dir"
        rm -f "$log_file"
        if [[ -f prepare.py ]]; then
            ./prepare.py
        fi

        set +e
        build_kata_rootfs
        rc=$?
        if (( rc == 0 )); then
            "$ARTIFACT_DIR/$TOOLS_DIR/severifast/config.sh"
            rc=$?
        fi
        if (( rc == 0 )); then
            "$ARTIFACT_DIR/$TOOLS_DIR/severifast/start.sh" launch "$log_file" "$times"
            rc=$?
        fi
        "$ARTIFACT_DIR/$TOOLS_DIR/severifast/config.sh" clean
        clean_firecracker_rootfs
        set -e

        popd
        if (( rc != 0 )); then
            break
        fi
    done

    echo
    echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) run_severifast_launch cleanup ==="
    "$TASK_DIR/run_severifast_launch/cleanup.sh"
    return "$rc"
}

echo "run_dir=$RUN_DIR"
echo "log_dir=$LOG_DIR"
echo "scope=$SCOPE include_kata_dna=$INCLUDE_KATA_DNA allow_sc_launch_fail=$ALLOW_SC_LAUNCH_FAIL allow_kata_fail=$ALLOW_KATA_FAIL"
echo "run_native=$RUN_NATIVE run_sc_launch=$RUN_SC_LAUNCH run_kata=$RUN_KATA"
echo "artifact_dir=$ARTIFACT_DIR"
echo "cntr_ip=$CNTR_IP host_ip=$HOST_IP"
echo "trace_root=$COFUNC_TRACE_ROOT"
echo "tdx_qemu=$COFUNC_TDX_QEMU"
echo "tdx_ovmf=$COFUNC_TDX_OVMF"

echo
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) build selected workload images ==="
for workload in "${!workloads[@]}"; do
    echo
    echo "=== build $workload ==="
    rebuild_workload "$workload"
done

if [[ "$RUN_NATIVE" == "1" ]]; then
    run_action_list run_lean_fork "${native_fork_params[@]}"
    run_action_list run_lean_launch "${native_launch_params[@]}"
fi
if [[ "$RUN_SC_LAUNCH" == "1" ]]; then
    if ! run_action_list run_sc_launch "${sc_launch_params[@]}"; then
        if [[ "$ALLOW_SC_LAUNCH_FAIL" == "1" ]]; then
            echo "WARNING: run_sc_launch failed; continuing without artifact-equivalent security add-on."
        else
            exit 1
        fi
    fi
fi
if [[ "$RUN_KATA" == "1" ]]; then
    if ! run_kata_list "${kata_params[@]}"; then
        if [[ "$ALLOW_KATA_FAIL" == "1" ]]; then
            echo "WARNING: run_severifast_launch failed; continuing without observed Kata."
        else
            exit 1
        fi
    fi
fi

echo
echo "=== $(date -u +%Y-%m-%dT%H:%M:%SZ) done ==="
echo "$RUN_DIR"
