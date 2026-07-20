#!/usr/bin/env bash
set -euo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ARTIFACT_DIR=${ARTIFACT_DIR:-/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact}
DOCKER_IMAGE=${DOCKER_IMAGE:-kata-tdx-fn_py_face_detection:latest}
CRI_IMAGE=${CRI_IMAGE:-docker.io/library/${DOCKER_IMAGE}}
SANDBOX_IMAGE=${SANDBOX_IMAGE:-registry.k8s.io/pause:3.8}
RUNTIME_HANDLER=${RUNTIME_HANDLER:-kata-qemu-tdx}
SNAPSHOTTER=${SNAPSHOTTER:-blockfile}
RUNTIME_ENDPOINT=${RUNTIME_ENDPOINT:-unix:///run/containerd/containerd.sock}
PARAM_URL=${PARAM_URL:-http://172.16.0.1:8888/get_param}
HOST_PARAM_URL=${HOST_PARAM_URL:-http://127.0.0.1:8888/get_param}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-120}
CRICTL_TIMEOUT="${TIMEOUT_SECONDS}s"
RUN_DIR=${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_cri_network_smoke_$(date -u +%Y%m%d_%H%M%S)}

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
# crictl defaults its client timeout to two seconds, which is shorter than a
# cold TDX Kata VM boot on this host.  Use the probe timeout consistently for
# both CRI connection setup and the RunPodSandbox request itself.
CRICTL=("${SUDO[@]}" crictl --runtime-endpoint "$RUNTIME_ENDPOINT" --timeout "$CRICTL_TIMEOUT")

mkdir -p "$RUN_DIR/cri-logs"
exec > >(tee -a "$RUN_DIR/runner.log") 2>&1

pod_config=$(mktemp)
container_config=$(mktemp)
archive=$(mktemp --suffix=.docker.tar)
pod_id=""
container_id=""
cleanup() {
    local rc=$?
    set +e
    if [[ -n "$container_id" ]]; then
        "${CRICTL[@]}" stop "$container_id" >/dev/null 2>&1 || true
        "${CRICTL[@]}" rm "$container_id" >/dev/null 2>&1 || true
    fi
    if [[ -n "$pod_id" ]]; then
        "${CRICTL[@]}" stopp "$pod_id" >/dev/null 2>&1 || true
        "${CRICTL[@]}" rmp "$pod_id" >/dev/null 2>&1 || true
    fi
    rm -f "$pod_config" "$container_config" "$archive"
    exit "$rc"
}
trap cleanup EXIT

echo "run_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "run_dir=$RUN_DIR"
echo "runtime_handler=$RUNTIME_HANDLER"
echo "snapshotter=$SNAPSHOTTER"
echo "cri_image=$CRI_IMAGE"
echo "sandbox_image=$SANDBOX_IMAGE"
echo "param_url=$PARAM_URL"

curl -fsS -X POST "$HOST_PARAM_URL" \
    --data-urlencode 'fn_name=testcases/fn_py_face_detection' >/dev/null || {
    echo "parameter helper is not ready at $HOST_PARAM_URL" >&2
    exit 1
}

"${SUDO[@]}" docker image inspect "$DOCKER_IMAGE" >/dev/null || {
    echo "missing Docker image: $DOCKER_IMAGE" >&2
    exit 1
}
"${SUDO[@]}" docker image inspect "$SANDBOX_IMAGE" >/dev/null || {
    echo "missing Docker pause image: $SANDBOX_IMAGE" >&2
    exit 1
}

import_image() {
    local image=$1
    "${SUDO[@]}" docker save -o "$archive" "$image"
    "${SUDO[@]}" ctr -n k8s.io images import \
        --local --platform linux/amd64 --snapshotter "$SNAPSHOTTER" "$archive"
    rm -f "$archive"
}

if ! "${SUDO[@]}" ctr -n k8s.io images ls -q | rg -Fx "$CRI_IMAGE" >/dev/null; then
    echo "importing workload image into CRI namespace"
    import_image "$DOCKER_IMAGE"
fi
if ! "${SUDO[@]}" ctr -n k8s.io images ls -q | rg -Fx "$SANDBOX_IMAGE" >/dev/null; then
    echo "importing pause image into CRI namespace"
    import_image "$SANDBOX_IMAGE"
fi

run_id=$(date -u +%Y%m%d%H%M%S)-$$
pod_name="kata-tdx-cri-net-$run_id"
jq -n --arg name "$pod_name" --arg uid "$run_id" --arg log_dir "$RUN_DIR/cri-logs" '{
    metadata: {name: $name, namespace: "default", uid: $uid, attempt: 1},
    hostname: $name,
    log_directory: $log_dir,
    linux: {}
}' >"$pod_config"

probe_code=$(cat <<'PY'
import urllib.parse
import urllib.request

body = urllib.parse.urlencode({"fn_name": "testcases/fn_py_face_detection"}).encode()
request = urllib.request.Request("PARAM_URL", data=body, method="POST")
with urllib.request.urlopen(request, timeout=15) as response:
    print("parameter_status=" + str(response.status))
PY
)
probe_code=${probe_code/PARAM_URL/$PARAM_URL}
jq -n --arg image "$CRI_IMAGE" --arg code "$probe_code" '{
    metadata: {name: "network-probe", attempt: 1},
    image: {image: $image},
    command: ["/usr/bin/python", "-c", $code],
    log_path: "network-probe.log",
    linux: {}
}' >"$container_config"

echo "creating CRI pod sandbox"
pod_id=$("${CRICTL[@]}" runp --cancel-timeout "$CRICTL_TIMEOUT" \
    --runtime "$RUNTIME_HANDLER" "$pod_config")
echo "pod_id=$pod_id"

echo "creating CRI probe container"
container_id=$("${CRICTL[@]}" create --no-pull "$pod_id" "$container_config" "$pod_config")
echo "container_id=$container_id"
"${CRICTL[@]}" start "$container_id" >/dev/null

deadline=$((SECONDS + TIMEOUT_SECONDS))
while (( SECONDS < deadline )); do
    state=$("${CRICTL[@]}" inspect -o json "$container_id" | jq -r '.status.state')
    if [[ "$state" == "CONTAINER_EXITED" ]]; then
        break
    fi
    sleep 1
done

"${CRICTL[@]}" logs "$container_id" | tee "$RUN_DIR/container.log"
inspect=$("${CRICTL[@]}" inspect -o json "$container_id")
printf '%s\n' "$inspect" >"$RUN_DIR/container-inspect.json"
state=$(jq -r '.status.state' <<<"$inspect")
exit_code=$(jq -r '.status.exitCode' <<<"$inspect")
echo "container_state=$state"
echo "container_exit_code=$exit_code"

if [[ "$state" != "CONTAINER_EXITED" || "$exit_code" != "0" ]]; then
    exit 1
fi

echo "Kata-TDX CRI cold-plug network smoke passed"
