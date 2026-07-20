#!/usr/bin/env bash
# Run one FunctionBench workload through the Kata CRI cold-plug path.
#
# The CRI pod sandbox is intentionally recreated for every sample.  Reusing a
# pod would retain the Kata VM and turn the result into a warm-container
# measurement.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ARTIFACT_DIR=${ARTIFACT_DIR:-/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact}
RUNTIME_HANDLER=${RUNTIME_HANDLER:-kata-qemu-tdx}
SNAPSHOTTER=${SNAPSHOTTER:-blockfile}
RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-300}
CRICTL_TIMEOUT="${TIMEOUT_SECONDS}s"
SANDBOX_IMAGE=${SANDBOX_IMAGE:-registry.k8s.io/pause:3.8}
CNI_GATEWAY=${CNI_GATEWAY:-172.16.0.1}
SCRATCH_FILE=${SCRATCH_FILE:-/Serverless/containerd/data/kata-blockfile/scratch-2g.ext4}
KATA_CONFIG=${KATA_CONFIG:-/etc/kata-containers/configuration-qemu-tdx-blockroot.toml}
CNI_CONFIG=${CNI_CONFIG:-/etc/cni/net.d/00-cofunc-tdx.conflist}
KATA_VCPU_CPU=${KATA_VCPU_CPU:-}
EPT_TRACE_BASE_URL=${EPT_TRACE_BASE_URL:-}
HOST_SAFETY_GATE=${HOST_SAFETY_GATE:-$BUNDLE/scripts/kata_tdx_host_safety_gate.sh}
PREPARE_ONLY=${PREPARE_ONLY:-0}
SKIP_PREPARE=${SKIP_PREPARE:-0}
# Leave completed cold samples immutable when a caller resumes a deliberately
# bounded batch.  The default preserves the original one-based numbering.
START_ITERATION=${START_ITERATION:-1}
RUN_TOKEN=${RUN_TOKEN:-$(date -u +%Y%m%d%H%M%S)-$$}

usage() {
    cat <<'EOF'
Usage:
  sudo run_kata_tdx_cri_workload.sh <workload-path> <repetitions>

The workload path is relative to testcases/testcases, for example
fn_py_sentiment or chain_js_alexa/fn_js_alexa_frontend.  PREPARE_ONLY=1
performs service validation, input preparation, image build, and image import
without creating a CRI pod; the Fig. 11 orchestrator uses this before its
timed samples.

Set START_ITERATION to a positive one-based sample number only when appending
to a validated, incomplete batch.  Existing sample directories are never
overwritten.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

need_command() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_sudo() {
    if (( EUID == 0 )); then
        SUDO=()
        return
    fi

    SUDO=(sudo)
    sudo -n true 2>/dev/null || die "sudo credentials are not cached; run sudo -v and retry"
}

run_host_safety_gate() {
    local context=$1
    "${SUDO[@]}" "$HOST_SAFETY_GATE" "$context"
}

kernel_allows_tdx_cleanup() {
    local context=$1 output

    if output=$("${SUDO[@]}" "$HOST_SAFETY_GATE" --kernel-only "$context" 2>&1); then
        return 0
    fi
    printf '%s\n' "$output" >&2
    return 1
}

run_as_invoking_user() {
    if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
        local prepare_home
        prepare_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        runuser -u "$SUDO_USER" -- env \
            HOME="$prepare_home" \
            USER="$SUDO_USER" \
            LOGNAME="$SUDO_USER" \
            PATH="$PATH" \
            "$@"
    else
        "$@"
    fi
}

pin_kata_vcpu() {
    local sandbox_id=$1 evidence_file=$2 pid_file qemu_pid tid comm attempt
    local online
    local -a tids

    [[ -n "$KATA_VCPU_CPU" ]] || return 0
    [[ "$KATA_VCPU_CPU" =~ ^[0-9]+$ ]] || \
        die "KATA_VCPU_CPU must be a non-negative CPU number: $KATA_VCPU_CPU"
    [[ -d "/sys/devices/system/cpu/cpu${KATA_VCPU_CPU}" ]] || \
        die "KATA_VCPU_CPU does not exist: $KATA_VCPU_CPU"
    if [[ -r "/sys/devices/system/cpu/cpu${KATA_VCPU_CPU}/online" ]]; then
        online=$(<"/sys/devices/system/cpu/cpu${KATA_VCPU_CPU}/online")
        [[ "$online" == 1 ]] || die "KATA_VCPU_CPU is offline: $KATA_VCPU_CPU"
    fi

    pid_file="/run/vc/vm/$sandbox_id/pid"
    for attempt in {1..50}; do
        "${SUDO[@]}" test -s "$pid_file" && break
        sleep 0.1
    done
    "${SUDO[@]}" test -s "$pid_file" || \
        die "missing QEMU PID file for vCPU pinning: $pid_file"
    qemu_pid=$("${SUDO[@]}" cat "$pid_file")
    [[ "$qemu_pid" =~ ^[1-9][0-9]*$ ]] && \
        "${SUDO[@]}" test -d "/proc/$qemu_pid/task" || \
        die "invalid QEMU PID for vCPU pinning: ${qemu_pid:-missing}"

    : >"$evidence_file"
    printf 'sandbox_id=%s\nqemu_pid=%s\ntarget_cpu=%s\n' \
        "$sandbox_id" "$qemu_pid" "$KATA_VCPU_CPU" >>"$evidence_file"
    mapfile -t tids < <("${SUDO[@]}" find "/proc/$qemu_pid/task" \
        -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -n)
    for tid in "${tids[@]}"; do
        comm=$("${SUDO[@]}" cat "/proc/$qemu_pid/task/$tid/comm")
        if [[ "$comm" =~ ^CPU[[:space:]][0-9]+/KVM$ ]]; then
            printf 'vcpu_tid=%s vcpu_comm=%s\n' "$tid" "$comm" >>"$evidence_file"
            "${SUDO[@]}" taskset -pc "$KATA_VCPU_CPU" "$tid" >>"$evidence_file"
            "${SUDO[@]}" taskset -pc "$tid" >>"$evidence_file"
        fi
    done
    rg -q '^vcpu_tid=[0-9]+ ' "$evidence_file" || \
        die "no QEMU KVM vCPU thread found for sandbox $sandbox_id"
    rg -q "current affinity list: ${KATA_VCPU_CPU}$" "$evidence_file" || \
        die "QEMU KVM vCPU affinity did not verify as CPU $KATA_VCPU_CPU"
}

valid_workload_path() {
    local path=$1
    [[ -n "$path" && "$path" != /* && "$path" != *"//"* ]] || return 1
    [[ "/$path/" != *"/../"* && "/$path/" != *"/./"* ]] || return 1
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
}

has_cri_image() {
    local image=$1
    "${SUDO[@]}" ctr -n k8s.io images ls -q | rg -Fx -- "$image" >/dev/null
}

cri_can_resolve_image() {
    local image=$1
    "${CRICTL[@]}" inspecti "$image" >/dev/null 2>&1
}

containerd_image_has_label() {
    local image=$1 label=$2

    "${SUDO[@]}" ctr -n k8s.io images ls | awk -v image="$image" -v label="$label" '
        NR > 1 && $1 == image {
            count = split($NF, labels, ",")
            for (i = 1; i <= count; i++) {
                if (index(labels[i], label "=") == 1) {
                    found = 1
                }
            }
        }
        END { exit !found }
    '
}

make_cri_image_visible() {
    local image=$1

    "${SUDO[@]}" ctr -n k8s.io images label "$image" \
        io.cri-containerd.image=managed >/dev/null
    cri_can_resolve_image "$image" || \
        die "containerd image is not resolvable through CRI after labeling: $image"
}

pin_workload_image() {
    local image=$1

    if containerd_image_has_label "$image" io.cri-containerd.pinned; then
        log "preserving existing CRI image pin: $image"
        return
    fi

    "${SUDO[@]}" ctr -n k8s.io images label "$image" \
        io.cri-containerd.image=managed \
        io.cri-containerd.pinned=pinned >/dev/null
    pinned_image=$image
    pinned_by_runner=1
    containerd_image_has_label "$image" io.cri-containerd.pinned || \
        die "failed to pin CRI image against kubelet image GC: $image"
    cri_can_resolve_image "$image" || \
        die "pinned image is not resolvable through CRI: $image"
    log "temporarily pinned CRI workload image against kubelet image GC: $image"
}

release_workload_image_pin() {
    (( pinned_by_runner )) || return

    if has_cri_image "$pinned_image"; then
        if "${SUDO[@]}" ctr -n k8s.io images label "$pinned_image" \
            io.cri-containerd.pinned= \
            io.cri-containerd.pinned-= >/dev/null && \
            ! containerd_image_has_label "$pinned_image" io.cri-containerd.pinned && \
            ! containerd_image_has_label "$pinned_image" io.cri-containerd.pinned-; then
            log "released temporary CRI workload image pin: $pinned_image"
        else
            log "warning: failed to release temporary CRI workload image pin: $pinned_image"
        fi
    fi
    pinned_by_runner=0
    pinned_image=""
}

containerd_image_digest() {
    local image=$1
    # ctr 2.2 has no JSON output for image metadata.  Its tabular list has a
    # stable third column for the target digest and does not vary by labels.
    "${SUDO[@]}" ctr -n k8s.io images ls | awk -v image="$image" '
        NR > 1 && $1 == image { print $3; exit }
    '
}

import_image() {
    local docker_image=$1
    local cri_image=$2
    local source_ref=$3

    archive=$(mktemp --suffix=.docker.tar)
    "${SUDO[@]}" docker save -o "$archive" "$docker_image"
    "${SUDO[@]}" ctr -n k8s.io images import \
        --local --platform linux/amd64 --snapshotter "$SNAPSHOTTER" "$archive"
    # docker save ran through sudo, so its archive can be root-owned in the
    # sticky /tmp directory.  Delete it with the same privilege context.
    "${SUDO[@]}" rm -f "$archive"
    archive=""

    has_cri_image "$cri_image" || die "image import did not create CRI name: $cri_image"
    "${SUDO[@]}" ctr -n k8s.io images tag --force "$cri_image" "$source_ref" >/dev/null
    has_cri_image "$source_ref" || die "image import did not create source identity name: $source_ref"
}

ensure_cri_image() {
    local docker_image=$1
    local cri_image=$2
    local pin_image=${3:-0}
    local docker_id source_ref

    docker_id=$("${SUDO[@]}" docker image inspect --format '{{.Id}}' "$docker_image")
    # Replace the existing tag (which is not always `latest`, e.g. pause:3.8)
    # with an immutable source-ID tag.
    source_ref="${cri_image%:*}:source-${docker_id#sha256:}"

    if has_cri_image "$cri_image" && has_cri_image "$source_ref"; then
        log "containerd image already matches Docker source: $cri_image (${docker_id})"
    else
        log "importing image into CRI namespace: $cri_image"
        import_image "$docker_image" "$cri_image" "$source_ref"
    fi

    make_cri_image_visible "$cri_image"
    if (( pin_image )); then
        pin_workload_image "$cri_image"
    fi
}

check_blockfile_capacity() {
    local image=$1
    local image_bytes scratch_bytes free_bytes

    "${SUDO[@]}" test -e "$SCRATCH_FILE" || die "missing blockfile scratch image: $SCRATCH_FILE"
    image_bytes=$("${SUDO[@]}" docker image inspect --format '{{.Size}}' "$image")
    scratch_bytes=$("${SUDO[@]}" stat -c '%s' "$SCRATCH_FILE")
    free_bytes=$("${SUDO[@]}" df -B1 --output=avail "$(dirname "$SCRATCH_FILE")" | tail -n 1 | tr -d '[:space:]')
    [[ "$image_bytes" =~ ^[0-9]+$ && "$scratch_bytes" =~ ^[0-9]+$ && "$free_bytes" =~ ^[0-9]+$ ]] || \
        die "could not determine blockfile capacity for $image"

    {
        echo "blockfile_scratch_file=$SCRATCH_FILE"
        echo "blockfile_scratch_bytes=$scratch_bytes"
        echo "blockfile_free_bytes=$free_bytes"
        echo "derived_image_bytes=$image_bytes"
    } >>"$RUN_DIR/run-env.txt"

    (( image_bytes <= scratch_bytes )) || die \
        "derived image is larger than the configured blockfile scratch image (${image_bytes} > ${scratch_bytes})"
    (( image_bytes <= free_bytes )) || die \
        "insufficient filesystem space for the derived image (${image_bytes} > ${free_bytes})"
}

run_prepare() {
    if [[ ! -f "$WORKLOAD_DIR/prepare.py" ]]; then
        return
    fi

    log "preparing workload input outside the timed region"
    (
        cd "$WORKLOAD_DIR"
        run_as_invoking_user ./prepare.py
    )
}

check_helper_services() {
    local needs_minio=0 needs_file_server=0 needs_device=0

    case "$WORKLOAD" in
        fn_py_face_detection|fn_py_image_processing|fn_py_compression|fn_py_dna_visualisation|fn_py_video_processing|fn_js_thumbnailer|fn_js_uploader)
            needs_minio=1
            ;;
    esac
    case "$WORKLOAD" in
        fn_js_uploader) needs_file_server=1 ;;
    esac
    case "$WORKLOAD" in
        chain_js_alexa/fn_js_alexa_tv) needs_device=1 ;;
    esac

    curl --connect-timeout 5 --max-time 15 -fsS -X POST \
        http://127.0.0.1:8888/get_param \
        --data-urlencode "fn_name=testcases/$WORKLOAD" >/dev/null || \
        die "parameter helper is not ready for testcases/$WORKLOAD at http://127.0.0.1:8888/get_param"

    if (( needs_minio )); then
        curl --connect-timeout 5 --max-time 15 -fsS \
            http://127.0.0.1:9000/minio/health/ready >/dev/null || \
            die "MinIO is not ready at http://127.0.0.1:9000"
    fi
    if (( needs_file_server )); then
        curl --connect-timeout 5 --max-time 15 -fsS \
            http://127.0.0.1:8080/ >/dev/null || \
            die "file server is not ready at http://127.0.0.1:8080"
    fi
    if (( needs_device )); then
        curl --connect-timeout 5 --max-time 15 -fsS \
            http://127.0.0.1:9090/ >/dev/null || \
            die "device service is not ready at http://127.0.0.1:9090"
    fi
}

ensure_source_image() {
    if "${SUDO[@]}" docker image inspect "$SOURCE_IMAGE" >/dev/null 2>&1; then
        return
    fi

    log "building missing artifact source image: $SOURCE_IMAGE"
    (
        cd "$WORKLOAD_DIR"
        "${SUDO[@]}" "$TOOLS_DIR/build.sh"
    )
}

ensure_derived_image() {
    local source_id derived_source_id

    source_id=$("${SUDO[@]}" docker image inspect --format '{{.Id}}' "$SOURCE_IMAGE")
    derived_source_id=$("${SUDO[@]}" docker image inspect \
        --format '{{with index .Config.Labels "cofunc.tdx.base-image-id"}}{{.}}{{end}}' \
        "$DERIVED_IMAGE" 2>/dev/null || true)
    if [[ "$derived_source_id" == "$source_id" ]]; then
        log "rewritten image already matches source: $DERIVED_IMAGE"
        return
    fi

    dockerfile=$(mktemp --suffix=.kata-tdx.Dockerfile)
    cat >"$dockerfile" <<'EOF'
ARG BASE_IMAGE=busybox:latest
FROM ${BASE_IMAGE}
RUN find /func -type f \( -name '*.py' -o -name '*.js' \) -print0 | xargs -0 -r sed -i 's#127\.0\.0\.1#CNI_GATEWAY#g'
EOF
    sed -i "s#CNI_GATEWAY#${CNI_GATEWAY}#g" "$dockerfile"
    log "building rewritten Kata image: $DERIVED_IMAGE"
    "${SUDO[@]}" docker build \
        --build-arg "BASE_IMAGE=$SOURCE_IMAGE" \
        --label "cofunc.tdx.base-image-id=$source_id" \
        -t "$DERIVED_IMAGE" \
        -f "$dockerfile" /tmp >/dev/null
    rm -f "$dockerfile"
    dockerfile=""
}

wait_for_cri_container_absent() {
    local id=$1 attempt listing
    for attempt in 1 2 3 4 5; do
        if listing=$("${CRICTL[@]}" ps -a -o json 2>/dev/null) &&
            ! jq -e --arg id "$id" '.containers[]? | select(.id == $id)' <<<"$listing" >/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_for_cri_pod_absent() {
    local id=$1 attempt listing
    for attempt in 1 2 3 4 5; do
        if listing=$("${CRICTL[@]}" pods -o json 2>/dev/null) &&
            ! jq -e --arg id "$id" '.items[]? | select(.id == $id)' <<<"$listing" >/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

cleanup_current_sample() {
    local failed=0 current_container=$container_id current_pod=$pod_id

    if [[ -z $current_container && -z $current_pod ]]; then
        return 0
    fi
    if ! kernel_allows_tdx_cleanup "before-cleanup-${RUN_TOKEN}"; then
        log "safety stop: preserving CRI IDs because the current boot has a KVM/TDX stop marker"
        return 1
    fi

    if [[ -n $current_container ]]; then
        "${CRICTL[@]}" stop "$current_container" >/dev/null 2>&1 || true
        "${CRICTL[@]}" rm "$current_container" >/dev/null 2>&1 || true
        if wait_for_cri_container_absent "$current_container"; then
            container_id=""
        else
            log "error: CRI container remains after cleanup: $current_container"
            failed=1
        fi
    fi
    if [[ -n $current_pod ]]; then
        "${CRICTL[@]}" stopp "$current_pod" >/dev/null 2>&1 || true
        "${CRICTL[@]}" rmp "$current_pod" >/dev/null 2>&1 || true
        if wait_for_cri_pod_absent "$current_pod"; then
            pod_id=""
        else
            log "error: CRI pod remains after cleanup: $current_pod"
            failed=1
        fi
    fi
    return "$failed"
}

cleanup() {
    local rc=$? cleanup_rc=0 safety_rc=0
    set +e
    cleanup_current_sample || cleanup_rc=$?
    release_workload_image_pin
    [[ -z "$archive" ]] || "${SUDO[@]}" rm -f "$archive"
    [[ -z "$dockerfile" ]] || rm -f "$dockerfile"
    if [[ -x $HOST_SAFETY_GATE ]]; then
        run_host_safety_gate "runner-exit-${RUN_TOKEN}" || safety_rc=$?
    fi
    trap - EXIT
    if (( rc == 0 && cleanup_rc != 0 )); then
        rc=$cleanup_rc
    elif (( rc == 0 && safety_rc != 0 )); then
        rc=$safety_rc
    fi
    exit "$rc"
}

run_sample() {
    local iteration=$1 sample_name sample_dir sample_log pod_config container_config
    local run_id pod_name short_token guest_command inspect state exit_code marker

    run_host_safety_gate "before-${RUN_TOKEN}-sample-${iteration}"
    sample_name=$(printf 'sample-%03d' "$iteration")
    sample_dir="$WORKLOAD_LOG_DIR/$sample_name"
    [[ ! -e "$sample_dir" ]] || \
        die "refusing to overwrite existing cold-sample evidence: $sample_dir"
    sample_log="$sample_dir/container.log"
    pod_config="$sample_dir/pod.json"
    container_config="$sample_dir/container.json"
    mkdir -p "$sample_dir/cri-logs"

    run_id="${RUN_TOKEN}-${iteration}"
    # CRI uses hostname for this sandbox.  Keep it safely below Linux's 63
    # byte hostname limit; the full workload path remains in log paths,
    # parameter-service names, configs, and the unique pod UID.
    short_token=${RUN_TOKEN:0:30}
    pod_name="kata-tdx-cri-${short_token}-${iteration}"
    jq -n --arg name "$pod_name" --arg uid "$run_id" --arg log_dir "$sample_dir/cri-logs" --arg run_token "$RUN_TOKEN" '{
        metadata: {name: $name, namespace: "default", uid: $uid, attempt: 1},
        hostname: $name,
        log_directory: $log_dir,
        labels: {"cofunc.tdx.run-token": $run_token},
        linux: {}
    }' >"$pod_config"

    guest_command="printf 't_import_begin %s\\n' \$(date +%s.%7N); exec ${WORKLOAD_COMMAND}"
    local trace_url=""
    [[ -z "$EPT_TRACE_BASE_URL" ]] || trace_url="$EPT_TRACE_BASE_URL/$iteration"
    jq -n --arg image "$CRI_IMAGE" --arg command "$guest_command" --arg name "$SAFE_WORKLOAD" --arg run_token "$RUN_TOKEN" --arg trace_url "$trace_url" '{
        metadata: {name: $name, attempt: 1},
        image: {image: $image},
        command: ["/bin/sh", "-lc", $command],
        envs: (if $trace_url == "" then [] else [
            {key: "COFUNC_EPT_TRACE_URL", value: $trace_url}
        ] end),
        log_path: "workload.log",
        labels: {"cofunc.tdx.run-token": $run_token},
        linux: {}
    }' >"$container_config"

    log "creating cold CRI sandbox: workload=$WORKLOAD sample=$iteration"
    {
        echo "mode kata-launch"
        printf 't_launch_begin %s\n' "$(date +%s.%7N)"
    } >"$sample_log"
    pod_id=$("${CRICTL[@]}" runp --cancel-timeout "$CRICTL_TIMEOUT" \
        --runtime "$RUNTIME_HANDLER" "$pod_config")
    printf '%s\n' "$pod_id" >"$sample_dir/pod-id.txt"
    "${CRICTL[@]}" inspectp -o json "$pod_id" >"$sample_dir/pod-inspect.json" || true
    pin_kata_vcpu "$pod_id" "$sample_dir/vcpu-affinity.txt"

    container_id=$("${CRICTL[@]}" create --no-pull "$pod_id" "$container_config" "$pod_config")
    printf '%s\n' "$container_id" >"$sample_dir/container-id.txt"
    "${CRICTL[@]}" start "$container_id" >/dev/null

    local deadline=$((SECONDS + TIMEOUT_SECONDS))
    while (( SECONDS < deadline )); do
        inspect=$("${CRICTL[@]}" inspect -o json "$container_id")
        printf '%s\n' "$inspect" >"$sample_dir/container-inspect.json"
        state=$(jq -r '.status.state' <<<"$inspect")
        if [[ "$state" == CONTAINER_EXITED ]]; then
            break
        fi
        sleep 1
    done

    "${CRICTL[@]}" logs "$container_id" | tee -a "$sample_log"
    inspect=$("${CRICTL[@]}" inspect -o json "$container_id")
    printf '%s\n' "$inspect" >"$sample_dir/container-inspect.json"
    state=$(jq -r '.status.state' <<<"$inspect")
    exit_code=$(jq -r '.status.exitCode' <<<"$inspect")
    printf '%s\n' "$state" >"$sample_dir/container-state.txt"
    printf '%s\n' "$exit_code" >"$sample_dir/container-exit-code.txt"

    if [[ "$state" != CONTAINER_EXITED || "$exit_code" != 0 ]]; then
        die "workload failed: workload=$WORKLOAD sample=$iteration state=$state exit_code=$exit_code"
    fi
    for marker in t_launch_begin t_import_begin t_func_load_begin t_import_done t_func_done; do
        rg -q "^${marker} [0-9]" "$sample_log" || \
            die "missing timing marker $marker: workload=$WORKLOAD sample=$iteration"
    done

    "$ANALYZER" --input-log "$sample_log" --log "$WORKLOAD_LOG_DIR/kata_launch.log"
    cp "$sample_dir/pod-inspect.json" "$sample_dir/pod-inspect-before-cleanup.json" 2>/dev/null || true
    cleanup_current_sample
    run_host_safety_gate "after-${RUN_TOKEN}-sample-${iteration}"
}

if (( $# != 2 )); then
    usage >&2
    exit 2
fi

WORKLOAD=$1
REPETITIONS=$2
valid_workload_path "$WORKLOAD" || die "invalid workload path: $WORKLOAD"
[[ "$REPETITIONS" =~ ^[1-9][0-9]*$ ]] || die "repetitions must be a positive whole number: $REPETITIONS"
[[ "$START_ITERATION" =~ ^[1-9][0-9]*$ ]] || \
    die "START_ITERATION must be a positive whole number: $START_ITERATION"
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "TIMEOUT_SECONDS must be a positive whole number"
[[ "$PREPARE_ONLY" == 0 || "$PREPARE_ONLY" == 1 ]] || die "PREPARE_ONLY must be 0 or 1"
[[ "$SKIP_PREPARE" == 0 || "$SKIP_PREPARE" == 1 ]] || die "SKIP_PREPARE must be 0 or 1"
[[ "$CNI_GATEWAY" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid CNI_GATEWAY: $CNI_GATEWAY"
[[ -z "$KATA_VCPU_CPU" || "$KATA_VCPU_CPU" =~ ^[0-9]+$ ]] || \
    die "KATA_VCPU_CPU must be empty or a non-negative CPU number: $KATA_VCPU_CPU"
[[ "$EPT_TRACE_BASE_URL" != *$'\n'* && "$EPT_TRACE_BASE_URL" != *$'\r'* ]] || \
    die "EPT_TRACE_BASE_URL must not contain a newline"

WORKLOAD_DIR="$ARTIFACT_DIR/testcases/testcases/$WORKLOAD"
TOOLS_DIR="$ARTIFACT_DIR/testcases/tools"
ANALYZER="$TOOLS_DIR/analyze.py"
SAFE_WORKLOAD=${WORKLOAD//\//_}
# Image builds in the artifact use the final workload directory name, not the
# path with its chain prefix.
SOURCE_IMAGE="$(basename "$WORKLOAD"):latest"
DERIVED_IMAGE="kata-tdx-$(basename "$WORKLOAD"):latest"
CRI_IMAGE="docker.io/library/${DERIVED_IMAGE}"
RUN_DIR=${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_workload_$(date -u +%Y%m%d_%H%M%S)}
LOG_ROOT=${LOG_ROOT:-$RUN_DIR/log}
WORKLOAD_LOG_DIR="$LOG_ROOT/$WORKLOAD"
archive=""
dockerfile=""
pod_id=""
container_id=""
pinned_image=""
pinned_by_runner=0

need_sudo
for command in curl docker ctr crictl jq rg df stat; do
    need_command "$command"
done
if [[ -n "$KATA_VCPU_CPU" ]]; then
    for command in cat find sort taskset; do
        need_command "$command"
    done
fi
[[ -d "$WORKLOAD_DIR" ]] || die "missing workload directory: $WORKLOAD_DIR"
[[ -r "$WORKLOAD_DIR/command" ]] || die "missing workload command file: $WORKLOAD_DIR/command"
[[ -x "$TOOLS_DIR/build.sh" ]] || die "missing workload image builder: $TOOLS_DIR/build.sh"
[[ -x "$ANALYZER" ]] || die "missing analyzer: $ANALYZER"
[[ -x "$HOST_SAFETY_GATE" ]] || die "missing host safety gate: $HOST_SAFETY_GATE"

WORKLOAD_COMMAND=$(<"$WORKLOAD_DIR/command")
[[ -n "$WORKLOAD_COMMAND" && "$WORKLOAD_COMMAND" != *$'\n'* && "$WORKLOAD_COMMAND" != *$'\r'* ]] || \
    die "workload command must contain exactly one non-empty line: $WORKLOAD_DIR/command"

mkdir -p "$RUN_DIR" "$WORKLOAD_LOG_DIR"
CRICTL_CONFIG="$RUN_DIR/crictl.yaml"
cat >"$CRICTL_CONFIG" <<EOF
runtime-endpoint: $RUNTIME_ENDPOINT
timeout: $TIMEOUT_SECONDS
EOF
CRICTL=("${SUDO[@]}" crictl --config "$CRICTL_CONFIG" --runtime-endpoint "$RUNTIME_ENDPOINT" --timeout "$CRICTL_TIMEOUT")
exec > >(tee -a "$RUN_DIR/runner.log") 2>&1
trap cleanup EXIT

run_host_safety_gate "workload-start-${RUN_TOKEN}"

plugin_status=$("${SUDO[@]}" ctr plugins ls | awk \
    '$1 == "io.containerd.snapshotter.v1" && $2 == "blockfile" { print $4 }')
[[ "$SNAPSHOTTER" == blockfile ]] || die "this runner requires SNAPSHOTTER=blockfile"
[[ "$plugin_status" == ok ]] || die "containerd blockfile snapshotter is not ready (${plugin_status:-missing})"
"${SUDO[@]}" rg -Fx 'shared_fs = "none"' "$KATA_CONFIG" >/dev/null || \
    die "active Kata config is not the required block-rootfs config: $KATA_CONFIG"
"${SUDO[@]}" rg -Fx 'block_device_aio = "threads"' "$KATA_CONFIG" >/dev/null || \
    die "active Kata config does not use QEMU-7-compatible block AIO threads: $KATA_CONFIG"
"${SUDO[@]}" test -r "$CNI_CONFIG" || die "missing expected CRI CNI config: $CNI_CONFIG"
"${SUDO[@]}" docker image inspect "$SANDBOX_IMAGE" >/dev/null || \
    die "missing Docker pause image: $SANDBOX_IMAGE"

{
    echo "run_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "run_dir=$RUN_DIR"
    echo "log_root=$LOG_ROOT"
    echo "workload=$WORKLOAD"
    echo "workload_command=$WORKLOAD_COMMAND"
    echo "source_image=$SOURCE_IMAGE"
    echo "derived_image=$DERIVED_IMAGE"
    echo "cri_image=$CRI_IMAGE"
    echo "sandbox_image=$SANDBOX_IMAGE"
    echo "runtime_handler=$RUNTIME_HANDLER"
    echo "runtime_endpoint=$RUNTIME_ENDPOINT"
    echo "snapshotter=$SNAPSHOTTER"
    echo "kata_config=$KATA_CONFIG"
    echo "cni_config=$CNI_CONFIG"
    echo "timeout_seconds=$TIMEOUT_SECONDS"
    echo "start_iteration=$START_ITERATION"
    echo "end_iteration=$((START_ITERATION + REPETITIONS - 1))"
    echo "cni_gateway=$CNI_GATEWAY"
    echo "kata_vcpu_cpu=${KATA_VCPU_CPU:-uncontrolled}"
    echo "ept_trace_window=$([[ -n "$EPT_TRACE_BASE_URL" ]] && echo enabled || echo disabled)"
    echo "run_token=$RUN_TOKEN"
    echo "prepare_only=$PREPARE_ONLY"
    echo "skip_prepare=$SKIP_PREPARE"
} >"$RUN_DIR/run-env.txt"

# This must happen before prepare/build/import/pod creation: runners must not
# mutate shared helpers or hide a missing service by starting one themselves.
check_helper_services
if [[ "$SKIP_PREPARE" == 0 ]]; then
    run_prepare
fi
ensure_source_image
ensure_derived_image
check_blockfile_capacity "$DERIVED_IMAGE"
ensure_cri_image "$DERIVED_IMAGE" "$CRI_IMAGE" 1
ensure_cri_image "$SANDBOX_IMAGE" "$SANDBOX_IMAGE" 0

{
    echo "source_image_id=$("${SUDO[@]}" docker image inspect --format '{{.Id}}' "$SOURCE_IMAGE")"
    echo "derived_image_id=$("${SUDO[@]}" docker image inspect --format '{{.Id}}' "$DERIVED_IMAGE")"
    echo "cri_image_digest=$(containerd_image_digest "$CRI_IMAGE")"
    echo "cri_image_pinned_by_runner=$pinned_by_runner"
    echo "sandbox_image_digest=$(containerd_image_digest "$SANDBOX_IMAGE")"
} >>"$RUN_DIR/run-env.txt"

if [[ "$PREPARE_ONLY" == 1 ]]; then
    log "prepared workload without launching a pod: $WORKLOAD"
    exit 0
fi

for iteration in $(seq "$START_ITERATION" "$((START_ITERATION + REPETITIONS - 1))"); do
    run_sample "$iteration"
done

log "Kata-TDX CRI workload passed: workload=$WORKLOAD samples=$REPETITIONS"
echo "$WORKLOAD_LOG_DIR/kata_launch.log"
