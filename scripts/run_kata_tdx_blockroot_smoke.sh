#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
KATA_CONFIG=${KATA_CONFIG:-$BUNDLE/configs/configuration-qemu-tdx-artifact-qemu7-blockroot-normalmem.toml}
SNAPSHOTTER=${SNAPSHOTTER:-blockfile}
CONTAINERD_NS=${CONTAINERD_NS:-default}
KATA_RUNTIME_TYPE=${KATA_RUNTIME_TYPE:-io.containerd.kata-qemu-tdx.v2}
IMAGE=${IMAGE:-docker.io/library/busybox:1.36.1}
PLATFORM=${PLATFORM:-linux/amd64}
SKIP_PULL=${SKIP_PULL:-0}
TIMEOUT_SEC=${TIMEOUT_SEC:-180}
STAMP=$(date -u +%Y%m%d_%H%M%S)
RUN_DIR=${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_blockroot_smoke_$STAMP}
CONTAINER_ID=${CONTAINER_ID:-kata-tdx-blockroot-smoke-$STAMP-$$}

die() {
    echo "error: $*" >&2
    exit 1
}

need_sudo() {
    if (( EUID == 0 )); then
        SUDO=()
        return
    fi

    SUDO=(sudo)
    sudo -n true 2>/dev/null || die "sudo credentials are not cached; run sudo -v and retry"
}

cleanup() {
    "${SUDO[@]}" /usr/bin/ctr -n "$CONTAINERD_NS" tasks kill "$CONTAINER_ID" >/dev/null 2>&1 || true
    "${SUDO[@]}" /usr/bin/ctr -n "$CONTAINERD_NS" tasks rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
    "${SUDO[@]}" /usr/bin/ctr -n "$CONTAINERD_NS" containers rm "$CONTAINER_ID" >/dev/null 2>&1 || true
}

need_sudo
[[ -r "$KATA_CONFIG" ]] || die "missing Kata config: $KATA_CONFIG"
rg -Fqx 'path = "/home/booklyn/cofunc-tdx/scripts/qemu_tdx_oldabi_normalmem_wrapper.sh"' "$KATA_CONFIG" || \
    die "config does not select the old-ABI normalmem wrapper"
rg -Fqx 'disable_block_device_use = false' "$KATA_CONFIG" || \
    die "config does not permit block rootfs devices"
rg -Fqx 'shared_fs = "none"' "$KATA_CONFIG" || \
    die "config must use shared_fs = none"

plugin_status=$("${SUDO[@]}" /usr/bin/ctr plugins ls | awk \
    '$1 == "io.containerd.snapshotter.v1" && $2 == "blockfile" { print $4 }')
[[ "$SNAPSHOTTER" == blockfile ]] || die "this smoke script is intentionally limited to SNAPSHOTTER=blockfile"
[[ "$plugin_status" == ok ]] || die "containerd blockfile snapshotter is not ready (status: ${plugin_status:-missing})"

mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR/runner.log") 2>&1

export KATA_QEMU_WRAPPER_LOG="$RUN_DIR/qemu-wrapper.log"
export COFUNC_TDX_WRAPPER_QEMU_STDIO_LOG="$RUN_DIR/qemu.log"
export COFUNC_TDX_WRAPPER_SERIAL_LOG="$RUN_DIR/guest-serial.log"

{
    echo "run_dir=$RUN_DIR"
    echo "kata_config=$KATA_CONFIG"
    echo "snapshotter=$SNAPSHOTTER"
    echo "runtime=$KATA_RUNTIME_TYPE"
    echo "image=$IMAGE"
    echo "platform=$PLATFORM"
    echo "skip_pull=$SKIP_PULL"
    echo "container_id=$CONTAINER_ID"
    echo "timeout_sec=$TIMEOUT_SEC"
} >"$RUN_DIR/run-env.txt"

trap cleanup EXIT

case "$SKIP_PULL" in
    0)
        echo "pulling image into the blockfile snapshotter: $IMAGE"
        "${SUDO[@]}" /usr/bin/ctr -n "$CONTAINERD_NS" images pull \
            --local \
            --platform "$PLATFORM" \
            --snapshotter "$SNAPSHOTTER" "$IMAGE"
        ;;
    1)
        "${SUDO[@]}" /usr/bin/ctr -n "$CONTAINERD_NS" images ls -q | rg -Fx "$IMAGE" >/dev/null || \
            die "image is not already present in containerd: $IMAGE"
        echo "using existing blockfile image without pulling: $IMAGE"
        ;;
    *)
        die "SKIP_PULL must be 0 or 1"
        ;;
esac

echo "running minimal Kata-TDX block-rootfs smoke"
set +e
timeout --foreground --kill-after=30s "$TIMEOUT_SEC" \
    "${SUDO[@]}" /usr/bin/ctr -n "$CONTAINERD_NS" run --rm \
    --snapshotter "$SNAPSHOTTER" \
    --runtime "$KATA_RUNTIME_TYPE" \
    --runtime-config-path "$KATA_CONFIG" \
    "$IMAGE" "$CONTAINER_ID" true
rc=$?
set -e

if (( rc != 0 )); then
    echo "Kata-TDX block-rootfs smoke failed: rc=$rc" >&2
    exit "$rc"
fi

echo "Kata-TDX block-rootfs smoke passed"
