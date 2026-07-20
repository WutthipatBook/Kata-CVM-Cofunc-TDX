#!/usr/bin/env bash
# Collect the Fig. 11 workload matrix through the Kata CRI cold-plug runner.
#
# This script is intentionally fail-fast.  A failed measured sample is
# evidence, not a retry opportunity: it is preserved in its sample directory
# and stops the collection before a graph can hide the omission.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
ARTIFACT_DIR=${ARTIFACT_DIR:-$ROOT/cofunc-artifact}
GENERIC_RUNNER=${GENERIC_RUNNER:-$BUNDLE/scripts/run_kata_tdx_cri_workload.sh}
STAGE_BREAKDOWN=${STAGE_BREAKDOWN:-$BUNDLE/scripts/cofunc_e2e_stage_breakdown.py}
STAGE_CHARTS=${STAGE_CHARTS:-$BUNDLE/scripts/cofunc_e2e_stage_bar_charts.py}
KATA_RUNTIME=${KATA_RUNTIME:-/opt/kata/bin/kata-runtime}
KATA_CONFIG=${KATA_CONFIG:-/etc/kata-containers/configuration-qemu-tdx-blockroot.toml}
CONTAINERD_CONFIG=${CONTAINERD_CONFIG:-/etc/containerd/config.toml}
CNI_CONFIG=${CNI_CONFIG:-/etc/cni/net.d/00-cofunc-tdx.conflist}
HOST_SAFETY_GATE=${HOST_SAFETY_GATE:-$BUNDLE/scripts/kata_tdx_host_safety_gate.sh}
RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}
RUNTIME_HANDLER=${RUNTIME_HANDLER:-kata-qemu-tdx}
SNAPSHOTTER=${SNAPSHOTTER:-blockfile}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-300}
CRICTL_TIMEOUT="${TIMEOUT_SECONDS}s"
SCRATCH_FILE=${SCRATCH_FILE:-/Serverless/containerd/data/kata-blockfile/scratch-2g.ext4}
IMAGE_DIR=${IMAGE_DIR:-/home/booklyn/BookArchive/Images}
STAMP=${STAMP:-$(date -u +%Y%m%d_%H%M%S)}
RUN_DIR=${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_fig11_$STAMP}
LOG_DIR="$RUN_DIR/log"
# Keep the generated token short enough that every generic attempt remains
# visible in CRI's 63-byte hostname-derived pod name.
RUN_TOKEN=${RUN_TOKEN:-f11-${STAMP:9}-$$}
# `smokes` validates the selected workloads only.  `batch` collects only the
# selected workloads into RUN_DIR/log and can append validated missing samples
# with FIG11_RESUME=1.  `render` is read-only apart from graph outputs.
# Default to validation only.  A monolithic matrix is available solely through
# an explicit FIG11_MODE=full request; normal collection uses bounded batches.
FIG11_MODE=${FIG11_MODE:-smokes}
FIG11_WORKLOADS=${FIG11_WORKLOADS:-}
FIG11_RESUME=${FIG11_RESUME:-0}
RUN_GENERIC_ATTEMPT=0
KERNEL_STOP_RE='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
KERNEL_LOG_LOSS_RE='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages'

WORKLOADS=(
    "fn_py_dna_visualisation 10"
    "fn_py_compression 20"
    "fn_py_face_detection 20"
    "fn_py_image_processing 20"
    "fn_py_sentiment 20"
    "fn_py_video_processing 5"
    "fn_js_thumbnailer 20"
    "fn_js_uploader 20"
    "chain_js_alexa/fn_js_alexa_frontend 20"
    "chain_js_alexa/fn_js_alexa_interact 20"
    "chain_js_alexa/fn_js_alexa_smarthome 20"
    "chain_js_alexa/fn_js_alexa_tv 20"
)

die() {
    echo "error: $*" >&2
    exit 1
}

log() {
    printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

select_workloads() {
    local workload entry matched selected
    local -a requested

    SELECTED_ENTRIES=()
    if [[ -z $FIG11_WORKLOADS ]]; then
        SELECTED_ENTRIES=("${WORKLOADS[@]}")
        return
    fi

    read -r -a requested <<<"$FIG11_WORKLOADS"
    ((${#requested[@]} > 0)) || die "FIG11_WORKLOADS did not contain a workload"
    for workload in "${requested[@]}"; do
        matched=""
        for entry in "${WORKLOADS[@]}"; do
            if [[ ${entry% *} == "$workload" ]]; then
                matched=$entry
                break
            fi
        done
        [[ -n $matched ]] || die "unknown Fig. 11 workload in FIG11_WORKLOADS: $workload"
        for selected in "${SELECTED_ENTRIES[@]}"; do
            [[ ${selected% *} != "$workload" ]] || die "duplicate Fig. 11 workload: $workload"
        done
        SELECTED_ENTRIES+=("$matched")
    done
}

measurement_sample_count() {
    local workload=$1 sample_log

    sample_log="$LOG_DIR/$workload/kata_launch.log"
    if [[ ! -e $sample_log ]]; then
        printf '0\n'
        return
    fi
    [[ -s $sample_log ]] || die "empty measured log for $workload: $sample_log"
    jq -e -s '
        length > 0 and
        all(.[];
            type == "object" and
            ([.timestamp, .t_boot_cntr, .t_boot_func, .t_exec, .t_e2e] |
                all(type == "number")))
    ' "$sample_log" >/dev/null || die "invalid analyzer record in $sample_log"
    jq -s 'length' "$sample_log"
}

validate_measurement_artifacts() {
    local workload=$1 count=$2 root sample_dir sample_log marker iteration
    local -a sample_dirs

    root="$LOG_DIR/$workload"
    if (( count == 0 )); then
        [[ ! -d $root ]] || {
            mapfile -t sample_dirs < <(find "$root" -maxdepth 1 -mindepth 1 -type d \
                -name 'sample-[0-9][0-9][0-9]' -printf '%f\n' | sort)
            ((${#sample_dirs[@]} == 0)) || \
                die "sample artifacts exist without analyzer records for $workload"
        }
        return
    fi

    [[ -d $root ]] || die "missing measured sample directory: $root"
    mapfile -t sample_dirs < <(find "$root" -maxdepth 1 -mindepth 1 -type d \
        -name 'sample-[0-9][0-9][0-9]' -printf '%f\n' | sort)
    ((${#sample_dirs[@]} == count)) || \
        die "analyzer/sample-directory count mismatch for $workload: records=$count directories=${#sample_dirs[@]}"
    for ((iteration = 1; iteration <= count; iteration++)); do
        sample_dir="$root/$(printf 'sample-%03d' "$iteration")"
        sample_log="$sample_dir/container.log"
        [[ -d $sample_dir && -r $sample_log ]] || \
            die "missing cold-sample evidence for $workload iteration $iteration"
        [[ -r "$sample_dir/container-state.txt" && $(<"$sample_dir/container-state.txt") == CONTAINER_EXITED ]] || \
            die "sample did not exit cleanly: $sample_dir"
        [[ -r "$sample_dir/container-exit-code.txt" && $(<"$sample_dir/container-exit-code.txt") == 0 ]] || \
            die "sample has a non-zero exit code: $sample_dir"
        for marker in t_launch_begin t_import_begin t_func_load_begin t_import_done t_func_done; do
            rg -q "^${marker} [0-9]" "$sample_log" || \
                die "missing timing marker $marker in $sample_log"
        done
    done
}

need_sudo() {
    if (( EUID == 0 )); then
        SUDO=()
        return
    fi
    SUDO=(sudo)
    sudo -n true 2>/dev/null || die "sudo credentials are not cached; run sudo -v and retry"
}

capture_environment() {
    local output="$RUN_DIR/run-environment.txt"
    {
        echo "captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "kernel_release=$(uname -r)"
        echo "kernel_cmdline=$(</proc/cmdline)"
        echo "runtime_handler=$RUNTIME_HANDLER"
        echo "runtime_endpoint=$RUNTIME_ENDPOINT"
        echo "snapshotter=$SNAPSHOTTER"
        echo "kata_config=$KATA_CONFIG"
        echo "containerd_config=$CONTAINERD_CONFIG"
        echo "cni_config=$CNI_CONFIG"
        echo "scratch_file=$SCRATCH_FILE"
        echo "kata_version_begin"
        "$KATA_RUNTIME" --version 2>&1 || true
        echo "kata_version_end"
        echo "qemu_version_begin"
        qemu-system-x86_64 --version 2>&1 || true
        echo "qemu_version_end"
        echo "containerd_version=$(containerd --version 2>&1 || true)"
        echo "crictl_version=$(crictl --version 2>&1 || true)"
        echo "config_hashes_begin"
        "${SUDO[@]}" sha256sum "$KATA_CONFIG" "$CONTAINERD_CONFIG" "$CNI_CONFIG" 2>&1 || true
        echo "config_hashes_end"
        for module in kvm kvm_intel; do
            echo "module=$module"
            echo "module_srcversion=$(modinfo -F srcversion "$module" 2>/dev/null || true)"
            module_file=$(modinfo -F filename "$module" 2>/dev/null || true)
            echo "module_file=$module_file"
            [[ -z "$module_file" ]] || "${SUDO[@]}" sha256sum "$module_file" 2>&1 || true
        done
        echo "thp=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>&1 || true)"
        echo "cpu_governors_begin"
        for governor in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
            [[ -r "$governor" ]] || continue
            echo "${governor}=$(<"$governor")"
        done
        echo "cpu_governors_end"
        echo "host_load_begin"
        uptime
        cat /proc/loadavg
        ps -eo user,pid,ppid,stat,etimes,comm,args --sort=-etimes
        echo "host_load_end"
        echo "blockfile_capacity_begin"
        "${SUDO[@]}" stat -c 'scratch_bytes=%s allocated_512b_blocks=%b path=%n' "$SCRATCH_FILE" 2>&1 || true
        "${SUDO[@]}" df -h "$(dirname "$SCRATCH_FILE")" 2>&1 || true
        "${SUDO[@]}" df -B1 "$(dirname "$SCRATCH_FILE")" 2>&1 || true
        echo "blockfile_capacity_end"
    } >"$output"
}

run_preflight() {
    local label=$1
    local output="$RUN_DIR/preflight-${label}.log"

    if {
        echo "preflight=$label"
        echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        [[ -d "$ARTIFACT_DIR" ]]
        [[ -x "$GENERIC_RUNNER" ]]
        [[ -x "$HOST_SAFETY_GATE" ]]
        [[ -x "$STAGE_BREAKDOWN" ]]
        [[ -x "$STAGE_CHARTS" ]]
        [[ "$SNAPSHOTTER" == blockfile ]]
        [[ -r "$KATA_CONFIG" ]]
        "${SUDO[@]}" rg -Fx 'shared_fs = "none"' "$KATA_CONFIG"
        "${SUDO[@]}" rg -Fx 'block_device_aio = "threads"' "$KATA_CONFIG"
        "${SUDO[@]}" rg -q '^\s*snapshotter = "blockfile"' "$CONTAINERD_CONFIG"
        "${SUDO[@]}" test -r "$CNI_CONFIG"
        "${SUDO[@]}" ctr plugins ls | awk \
            '$1 == "io.containerd.snapshotter.v1" && $2 == "blockfile" && $4 == "ok" { found = 1 } END { exit !found }'
        "${CRICTL[@]}" info >/dev/null
        "${SUDO[@]}" stat -c 'scratch_bytes=%s allocated_512b_blocks=%b path=%n' "$SCRATCH_FILE"
        "${SUDO[@]}" df -B1 "$(dirname "$SCRATCH_FILE")"
        "${SUDO[@]}" "$HOST_SAFETY_GATE" "fig11-$label"
    } >"$output" 2>&1; then
        cat "$output"
    else
        cat "$output" >&2
        die "read-only CRI/Kata preflight failed at $label; do not restart or reconfigure shared services automatically"
    fi
}

capture_diagnostics() {
    local label=$1
    # util-linux dmesg on this host supports `iso`, not `iso-precise`.
    "${SUDO[@]}" dmesg --time-format iso >"$RUN_DIR/dmesg-${label}.log" 2>&1 || true
    "${CRICTL[@]}" pods -o json >"$RUN_DIR/cri-pods-${label}.json" 2>&1 || true
    "${CRICTL[@]}" ps -a -o json >"$RUN_DIR/cri-containers-${label}.json" 2>&1 || true
    ps -efww >"$RUN_DIR/processes-${label}.txt"
}

capture_failure_diagnostics() {
    local rc=$?

    trap - EXIT
    if (( rc != 0 )); then
        set +e
        log "Fig.11 run failed (exit=$rc); preserving post-failure diagnostics"
        capture_diagnostics failure
        if [[ -f "$RUN_DIR/dmesg-before.log" && -f "$RUN_DIR/dmesg-failure.log" ]]; then
            diff -u "$RUN_DIR/dmesg-before.log" "$RUN_DIR/dmesg-failure.log" 2>/dev/null |
                sed -n '/^+[^+]/p' >"$RUN_DIR/dmesg-failure.delta" || true
        fi
    fi
    exit "$rc"
}

verify_kernel_delta() {
    local before_label=$1 after_label=$2
    local kernel_delta="$RUN_DIR/dmesg-${after_label}.delta"
    diff -u "$RUN_DIR/dmesg-${before_label}.log" "$RUN_DIR/dmesg-${after_label}.log" 2>/dev/null |
        sed -n '/^+[^+]/p' >"$kernel_delta" || true

    if rg -n -i "$KERNEL_STOP_RE" "$kernel_delta"; then
        die "kernel/KVM/TDX regression found in $kernel_delta"
    fi
    if rg -n -i "$KERNEL_LOG_LOSS_RE" "$kernel_delta"; then
        die "kernel log loss found in $kernel_delta"
    fi
}

verify_no_run_leftovers() {
    local label=$1
    jq -e --arg token "$RUN_TOKEN" '
        [.items[]? | select(((.labels["cofunc.tdx.run-token"] // "") | startswith($token)) or ((.metadata.name // "") | contains($token)))] | length == 0
    ' "$RUN_DIR/cri-pods-${label}.json" >/dev/null || \
        die "a CRI test pod with run token $RUN_TOKEN remains after cleanup"
    jq -e --arg token "$RUN_TOKEN" '
        [.containers[]? | select(((.labels["cofunc.tdx.run-token"] // "") | startswith($token)) or ((.metadata.name // "") | contains($token)))] | length == 0
    ' "$RUN_DIR/cri-containers-${label}.json" >/dev/null || \
        die "a CRI test container with run token $RUN_TOKEN remains after cleanup"
    if rg -n --fixed-strings "$RUN_TOKEN" "$RUN_DIR/processes-${label}.txt"; then
        die "a process with run token $RUN_TOKEN remains after cleanup"
    fi
}

verify_postflight() {
    verify_kernel_delta before after
    verify_no_run_leftovers after
}

run_generic() {
    local phase=$1 workload=$2 repetitions=$3 log_root=$4 prepare_only=$5 skip_prepare=$6
    local start_iteration=${7:-1} safe_workload=${workload//\//_} phase_dir attempt

    ((++RUN_GENERIC_ATTEMPT))
    attempt="$(date -u +%Y%m%d_%H%M%S)-$$-${RUN_GENERIC_ATTEMPT}"
    phase_dir="$RUN_DIR/$phase/$safe_workload/attempt-$attempt"

    log "phase=$phase workload=$workload repetitions=$repetitions start_iteration=$start_iteration attempt=$attempt"
    RUN_DIR="$phase_dir" \
    LOG_ROOT="$log_root" \
    RUN_TOKEN="${RUN_TOKEN}-a${RUN_GENERIC_ATTEMPT}-${phase}-${safe_workload}" \
    PREPARE_ONLY="$prepare_only" \
    SKIP_PREPARE="$skip_prepare" \
    START_ITERATION="$start_iteration" \
    RUNTIME_HANDLER="$RUNTIME_HANDLER" \
    SNAPSHOTTER="$SNAPSHOTTER" \
    RUNTIME_ENDPOINT="$RUNTIME_ENDPOINT" \
    TIMEOUT_SECONDS="$TIMEOUT_SECONDS" \
    SCRATCH_FILE="$SCRATCH_FILE" \
    KATA_CONFIG="$KATA_CONFIG" \
    CNI_CONFIG="$CNI_CONFIG" \
    HOST_SAFETY_GATE="$HOST_SAFETY_GATE" \
    ARTIFACT_DIR="$ARTIFACT_DIR" \
    "$GENERIC_RUNNER" "$workload" "$repetitions"
}

new_auxiliary_log_root() {
    local phase=$1 workload=$2 safe_workload=${workload//\//_}

    printf '%s/%s/%s/attempt-%s-%s\n' \
        "$RUN_DIR" "${phase}-log" "$safe_workload" "$(date -u +%Y%m%d_%H%M%S)" "$$"
}

validate_sample_counts() {
    local entry workload expected actual
    local -a entries=("$@")

    ((${#entries[@]} > 0)) || entries=("${WORKLOADS[@]}")
    for entry in "${entries[@]}"; do
        workload=${entry% *}
        expected=${entry##* }
        actual=$(measurement_sample_count "$workload")
        validate_measurement_artifacts "$workload" "$actual"
        [[ "$actual" == "$expected" ]] || \
            die "sample count mismatch for $workload: expected=$expected actual=$actual"
    done
}

run_smoke_matrix() {
    local entry workload log_root

    for entry in "${SELECTED_ENTRIES[@]}"; do
        workload=${entry% *}
        log_root=$(new_auxiliary_log_root smoke "$workload")
        run_generic smokes "$workload" 1 "$log_root" 0 0
    done
}

run_measurement_batch() {
    local entry workload expected actual remaining start_iteration warmup_log_root

    for entry in "${SELECTED_ENTRIES[@]}"; do
        workload=${entry% *}
        expected=${entry##* }
        actual=$(measurement_sample_count "$workload")
        (( actual <= expected )) || \
            die "too many measured samples for $workload: expected=$expected actual=$actual"
        validate_measurement_artifacts "$workload" "$actual"

        if (( actual == expected )); then
            [[ "$FIG11_RESUME" == 1 ]] || \
                die "completed measurements already exist for $workload; use FIG11_RESUME=1 to preserve and skip them"
            log "resume: workload already complete; preserving $actual samples: $workload"
            continue
        fi
        if (( actual > 0 )) && [[ "$FIG11_RESUME" != 1 ]]; then
            die "incomplete measurements already exist for $workload; inspect the preserved boundary, then use explicit FIG11_RESUME=1 only after coordinated approval"
        fi

        # Image/input preparation remains outside the timed samples.  A resumed
        # batch deliberately does not create another warm-up if valid samples
        # already exist; that avoids overwriting its separate warm-up evidence.
        run_generic prebuild "$workload" 1 "$RUN_DIR/prebuild-log" 1 0
        if (( actual == 0 )); then
            warmup_log_root=$(new_auxiliary_log_root warmup "$workload")
            run_generic warmup "$workload" 1 "$warmup_log_root" 0 1
        fi

        remaining=$((expected - actual))
        start_iteration=$((actual + 1))
        run_generic measure "$workload" "$remaining" "$LOG_DIR" 0 1 "$start_iteration"
        validate_sample_counts "$entry"
    done
}

render_graphs() {
    local stem="kata_tdx_cri_fig11_${STAMP}"
    local json="$RUN_DIR/stage_breakdown_${stem}.json"
    local csv="$RUN_DIR/stage_breakdown_${stem}.csv"
    local markdown="$RUN_DIR/stage_breakdown_${stem}.md"
    local graph_dir="$RUN_DIR/graphs"
    local prefix="fig11-kata-tdx-cri-${STAMP}"

    "$STAGE_BREAKDOWN" \
        --log-root "$LOG_DIR" \
        --markdown "$markdown" \
        --csv "$csv" \
        --json "$json" \
        --max-gap-ms 1.0 >"$RUN_DIR/stage-breakdown.log"

    jq -e '
        [.rows[] | select(.mode == "cold-observed") | (.stage_sum_gap_s | if . < 0 then -. else . end) <= 0.001] | all
    ' "$json" >/dev/null || die "cold stage sum differs from E2E by more than 1 ms"
    jq -e '
        [.rows[] | select(.mode == "cold-observed") | .workload] | unique | length == 12
    ' "$json" >/dev/null || die "stage breakdown is missing a cold workload"

    mkdir -p "$graph_dir" "$IMAGE_DIR"
    "$STAGE_CHARTS" --input "$json" --out-dir "$graph_dir" --prefix "$prefix" \
        --title-prefix "Kata TDX CRI Fig. 11" --views full startup --format png \
        >"$RUN_DIR/stage-graphs-png.log"
    "$STAGE_CHARTS" --input "$json" --out-dir "$graph_dir" --prefix "$prefix" \
        --title-prefix "Kata TDX CRI Fig. 11" --views full startup --format pdf \
        >"$RUN_DIR/stage-graphs-pdf.log"
    find "$graph_dir" -maxdepth 1 -type f \( -name '*.png' -o -name '*.pdf' \) \
        -exec cp -f {} "$IMAGE_DIR" \;
    cp -f "$json" "$csv" "$markdown" "$IMAGE_DIR/"
}

main() {
    mkdir -p "$RUN_DIR" "$LOG_DIR"

    case "$FIG11_MODE" in
        full|smokes|batch|render) ;;
        *) die "FIG11_MODE must be full, smokes, batch, or render (got $FIG11_MODE)" ;;
    esac
    [[ "$FIG11_RESUME" == 0 || "$FIG11_RESUME" == 1 ]] || \
        die "FIG11_RESUME must be 0 or 1 (got $FIG11_RESUME)"
    select_workloads
    if [[ "$FIG11_MODE" == batch && -z $FIG11_WORKLOADS ]]; then
        die "FIG11_MODE=batch requires an explicit bounded FIG11_WORKLOADS selection"
    fi
    if [[ "$FIG11_MODE" == full && -n $FIG11_WORKLOADS ]]; then
        die "FIG11_WORKLOADS is only valid with FIG11_MODE=smokes or batch; full must retain the complete matrix"
    fi
    if [[ "$FIG11_MODE" == render ]]; then
        validate_sample_counts "${WORKLOADS[@]}"
        render_graphs
        log "Kata-TDX CRI Fig. 11 graphs completed: $RUN_DIR"
        return
    fi

    CRICTL_CONFIG="$RUN_DIR/crictl.yaml"
    cat >"$CRICTL_CONFIG" <<EOF
runtime-endpoint: $RUNTIME_ENDPOINT
timeout: $TIMEOUT_SECONDS
EOF
    exec > >(tee -a "$RUN_DIR/runner.log") 2>&1

    need_sudo
    CRICTL=("${SUDO[@]}" crictl --config "$CRICTL_CONFIG" --runtime-endpoint "$RUNTIME_ENDPOINT" --timeout "$CRICTL_TIMEOUT")
    trap capture_failure_diagnostics EXIT
    for command in awk containerd crictl ctr df diff find jq qemu-system-x86_64 rg sha256sum stat; do
        command -v "$command" >/dev/null 2>&1 || die "missing required command: $command"
    done
    [[ -x "$KATA_RUNTIME" ]] || die "missing required Kata runtime: $KATA_RUNTIME"
    [[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "TIMEOUT_SECONDS must be a positive whole number"

    capture_environment
    {
        echo "fig11_mode=$FIG11_MODE"
        echo "fig11_resume=$FIG11_RESUME"
        echo "fig11_workloads=${FIG11_WORKLOADS:-all}"
    } >>"$RUN_DIR/run-environment.txt"
    run_preflight "before-$FIG11_MODE"
    capture_diagnostics before

    case "$FIG11_MODE" in
        smokes)
            # Smoke records live outside LOG_DIR so they cannot inflate Fig. 11
            # cold-sample counts.  Each generic invocation has its own runner
            # directory and before/after host-safety gates.
            run_smoke_matrix
            ;;
        batch)
            # A batch is intentionally limited by FIG11_WORKLOADS.  It may be
            # rerun only with explicit resume mode after its evidence is read.
            run_measurement_batch
            validate_sample_counts "${SELECTED_ENTRIES[@]}"
            ;;
        full)
            run_smoke_matrix
            run_measurement_batch
            validate_sample_counts "${WORKLOADS[@]}"
            ;;
    esac

    run_preflight "after-$FIG11_MODE"
    capture_diagnostics after
    verify_postflight
    if [[ "$FIG11_MODE" == full ]]; then
        render_graphs
        log "Kata-TDX CRI Fig. 11 completed: $RUN_DIR"
    else
        log "Kata-TDX CRI Fig. 11 $FIG11_MODE completed: $RUN_DIR"
    fi
}

main "$@"
