#!/usr/bin/env bash
# Reclaim blockfile capacity by removing only completed Fig. 11 workload image
# references. Containerd owns snapshot garbage collection; this script never
# deletes snapshot files, snapshots, content, or leases directly.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
GATE=${GATE:-$BUNDLE/scripts/kata_tdx_host_safety_gate.sh}
BLOCK_ROOT=${BLOCK_ROOT:-/Serverless/containerd/data/kata-blockfile}
MIN_RECLAIM_BYTES=${MIN_RECLAIM_BYTES:-2147483648}
RUN_ROOT=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_completed_image_cleanup_$(date -u +%Y%m%d_%H%M%S)}
AUDIT=/home/booklyn/BookArchive/StageBreakdownRuns/serverless_capacity_audit_20260716_063027.txt
AUDIT_SHA256=f10ddeb0e9db263acbfda15e19006eef622a84f023cdc9162852b86349e219ac

completed_k8s_named=(
    docker.io/library/kata-tdx-fn_py_compression:latest
    docker.io/library/kata-tdx-fn_py_compression:source-1d7441bcdf635f514d0879ee3f28065421a8d9fcb9de6329f88cbdc981d53bf2
    docker.io/library/kata-tdx-fn_py_dna_visualisation:latest
    docker.io/library/kata-tdx-fn_py_dna_visualisation:source-7471863ad4c1880264c2498404a516c8db15231b664e3dae1e04e6dd2ce5a881
    docker.io/library/kata-tdx-fn_py_face_detection:latest
    docker.io/library/kata-tdx-fn_py_face_detection:source-d559a05df456434d7ac8845728e7931740144df9654e7576c93886cfcd0a11a8
    docker.io/library/kata-tdx-fn_py_video_processing:latest
    docker.io/library/kata-tdx-fn_py_video_processing:source-4961b5efd3c76d00fa37e0d9cab5f67537754fb00adef8e0e73c7268b70b9511
)
completed_k8s_digest=(
    sha256:1d7441bcdf635f514d0879ee3f28065421a8d9fcb9de6329f88cbdc981d53bf2
    sha256:7471863ad4c1880264c2498404a516c8db15231b664e3dae1e04e6dd2ce5a881
    sha256:d559a05df456434d7ac8845728e7931740144df9654e7576c93886cfcd0a11a8
    sha256:4961b5efd3c76d00fa37e0d9cab5f67537754fb00adef8e0e73c7268b70b9511
)
completed_k8s=("${completed_k8s_named[@]}" "${completed_k8s_digest[@]}")
completed_default=(
    docker.io/library/kata-tdx-fn_py_face_detection:latest
)
preserved_k8s=(
    docker.io/library/kata-tdx-fn_js_alexa_frontend:latest
    docker.io/library/kata-tdx-fn_js_alexa_frontend:source-5d99623c4d051b16556f847f077e9f2928a2381fca735568dab53ca8d498f4fd
    docker.io/library/kata-tdx-fn_js_alexa_smarthome:latest
    docker.io/library/kata-tdx-fn_js_alexa_smarthome:source-559a79fab15f0ac11ce497af4064dee330a0f2699dd31e50eaad44716bf45510
    registry.k8s.io/pause:3.8
)
docker_recovery_images=(
    fn_py_compression:latest
    kata-tdx-fn_py_compression:latest
    fn_py_dna_visualisation:latest
    kata-tdx-fn_py_dna_visualisation:latest
    fn_py_face_detection:latest
    kata-tdx-fn_py_face_detection:latest
    fn_py_video_processing:latest
    kata-tdx-fn_py_video_processing:latest
)

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

image_digest() {
    local namespace=$1 reference=$2
    ctr -n "$namespace" images ls | awk -v reference="$reference" '
        NR > 1 && $1 == reference && !found { print $3; found = 1 }
    '
}

require_image() {
    local namespace=$1 reference=$2 digest
    digest=$(image_digest "$namespace" "$reference")
    [[ -n $digest ]] || fail "required image reference is absent from $namespace: $reference"
    printf '%s %s %s\n' "$namespace" "$reference" "$digest"
}

require_absent_image() {
    local namespace=$1 reference=$2
    [[ -z $(image_digest "$namespace" "$reference") ]] ||
        fail "removed image reference remains in $namespace: $reference"
}

capture_inventory() {
    local label=$1 namespace
    df -B1 /Serverless >"$RUN_ROOT/df-$label.txt"
    du -B1 -s "$BLOCK_ROOT" >"$RUN_ROOT/blockfile-du-$label.txt"
    find "$BLOCK_ROOT" -xdev -type f -printf '%s %b %p\n' |
        sort -k3,3 >"$RUN_ROOT/blockfile-files-$label.txt"
    for namespace in default k8s.io; do
        ctr -n "$namespace" images ls >"$RUN_ROOT/$namespace-images-$label.txt"
        ctr -n "$namespace" images ls -q | sort -u >"$RUN_ROOT/$namespace-image-refs-$label.txt"
        ctr -n "$namespace" snapshots --snapshotter blockfile ls \
            >"$RUN_ROOT/$namespace-snapshots-$label.txt"
        ctr -n "$namespace" leases ls >"$RUN_ROOT/$namespace-leases-$label.txt"
    done
}

build_expected_refs() {
    local namespace=$1 input=$2 output=$3 reference tmp
    cp "$input" "$output"
    if [[ $namespace == k8s.io ]]; then
        for reference in "${completed_k8s[@]}"; do
            tmp="$output.tmp"
            awk -v reference="$reference" '$0 != reference' "$output" >"$tmp"
            mv "$tmp" "$output"
        done
    else
        for reference in "${completed_default[@]}"; do
            tmp="$output.tmp"
            awk -v reference="$reference" '$0 != reference' "$output" >"$tmp"
            mv "$tmp" "$output"
        done
    fi
}

(( EUID == 0 )) || fail "run this script with sudo"
for command in awk cmp ctr date df docker du find rg sha256sum sort; do
    need "$command"
done
[[ -x $GATE ]] || fail "missing host safety gate: $GATE"
[[ -d $BLOCK_ROOT ]] || fail "missing blockfile root: $BLOCK_ROOT"
[[ $MIN_RECLAIM_BYTES =~ ^[1-9][0-9]*$ ]] || fail "MIN_RECLAIM_BYTES must be positive"

mkdir -p "$RUN_ROOT"
exec > >(tee -a "$RUN_ROOT/cleanup.log") 2>&1
printf 'run_started=%s\nrun_root=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ROOT"
printf '%s  %s\n' "$AUDIT_SHA256" "$AUDIT" | sha256sum -c -
sha256sum "$0" >"$RUN_ROOT/script.sha256"

"$GATE" pre-completed-image-cleanup | tee "$RUN_ROOT/host-gate-before.txt"
rg -q '^host_safety=ready$' "$RUN_ROOT/host-gate-before.txt" || fail "pre-cleanup host gate is not ready"

printf 'Verifying local Docker recovery images\n'
for reference in "${docker_recovery_images[@]}"; do
    docker image inspect --format '{{.RepoTags}} {{.Id}} {{.Size}}' "$reference"
done | tee "$RUN_ROOT/docker-recovery-images.txt"

printf 'Verifying the exact approved containerd references\n'
: >"$RUN_ROOT/completed-k8s-images-before.txt"
present_k8s=()
for reference in "${completed_k8s[@]}"; do
    digest=$(image_digest k8s.io "$reference")
    if [[ -n $digest ]]; then
        present_k8s+=("$reference")
        printf 'k8s.io %s %s\n' "$reference" "$digest" |
            tee -a "$RUN_ROOT/completed-k8s-images-before.txt"
    fi
done
: >"$RUN_ROOT/completed-default-images-before.txt"
present_default=()
for reference in "${completed_default[@]}"; do
    digest=$(image_digest default "$reference")
    if [[ -n $digest ]]; then
        present_default+=("$reference")
        printf 'default %s %s\n' "$reference" "$digest" |
            tee -a "$RUN_ROOT/completed-default-images-before.txt"
    fi
done

if (( ${#present_k8s[@]} == ${#completed_k8s[@]} &&
      ${#present_default[@]} == ${#completed_default[@]} )); then
    cleanup_mode=full
elif (( ${#present_k8s[@]} == ${#completed_k8s_digest[@]} &&
        ${#present_default[@]} == 0 )); then
    cleanup_mode=residual-digests
    for reference in "${completed_k8s_digest[@]}"; do
        [[ -n $(image_digest k8s.io "$reference") ]] ||
            fail "residual cleanup state is missing digest reference: $reference"
    done
else
    fail "approved references are in neither the full nor residual-digest state"
fi
printf 'cleanup_mode=%s\n' "$cleanup_mode" | tee "$RUN_ROOT/cleanup-mode.txt"

for reference in "${preserved_k8s[@]}"; do
    require_image k8s.io "$reference"
done | tee "$RUN_ROOT/preserved-k8s-images-before.txt"

capture_inventory before
cp "$RUN_ROOT/k8s.io-leases-before.txt" "$RUN_ROOT/k8s.io-leases-expected.txt"
cp "$RUN_ROOT/default-leases-before.txt" "$RUN_ROOT/default-leases-expected.txt"
build_expected_refs k8s.io "$RUN_ROOT/k8s.io-image-refs-before.txt" \
    "$RUN_ROOT/k8s.io-image-refs-expected-after.txt"
build_expected_refs default "$RUN_ROOT/default-image-refs-before.txt" \
    "$RUN_ROOT/default-image-refs-expected-after.txt"

before_free=$(df -B1 --output=avail /Serverless | tail -n 1 | tr -d '[:space:]')
before_alloc=$(du -B1 -s "$BLOCK_ROOT" | awk '{print $1}')
[[ $before_free =~ ^[0-9]+$ && $before_alloc =~ ^[0-9]+$ ]] ||
    fail "could not measure pre-cleanup capacity"

printf 'Removing %s approved k8s.io references with synchronous GC\n' "${#present_k8s[@]}"
ctr -n k8s.io images rm --sync "${present_k8s[@]}" |
    tee "$RUN_ROOT/k8s.io-image-removal.txt"
if (( ${#present_default[@]} )); then
    printf 'Removing the approved legacy default reference with synchronous GC\n'
    ctr -n default images rm --sync "${present_default[@]}" |
        tee "$RUN_ROOT/default-image-removal.txt"
else
    printf 'Legacy default reference was already removed by the validated first phase\n' |
        tee "$RUN_ROOT/default-image-removal.txt"
fi

capture_inventory after
for reference in "${completed_k8s[@]}"; do
    require_absent_image k8s.io "$reference"
done
for reference in "${completed_default[@]}"; do
    require_absent_image default "$reference"
done
for reference in "${preserved_k8s[@]}"; do
    require_image k8s.io "$reference"
done | tee "$RUN_ROOT/preserved-k8s-images-after.txt"

cmp "$RUN_ROOT/k8s.io-image-refs-expected-after.txt" \
    "$RUN_ROOT/k8s.io-image-refs-after.txt" || fail "unexpected k8s.io image-reference change"
cmp "$RUN_ROOT/default-image-refs-expected-after.txt" \
    "$RUN_ROOT/default-image-refs-after.txt" || fail "unexpected default image-reference change"
cmp "$RUN_ROOT/k8s.io-leases-expected.txt" "$RUN_ROOT/k8s.io-leases-after.txt" ||
    fail "k8s.io lease inventory changed"
cmp "$RUN_ROOT/default-leases-expected.txt" "$RUN_ROOT/default-leases-after.txt" ||
    fail "default lease inventory changed"

after_free=$(df -B1 --output=avail /Serverless | tail -n 1 | tr -d '[:space:]')
after_alloc=$(du -B1 -s "$BLOCK_ROOT" | awk '{print $1}')
[[ $after_free =~ ^[0-9]+$ && $after_alloc =~ ^[0-9]+$ ]] ||
    fail "could not measure post-cleanup capacity"
reclaimed_free=$((after_free - before_free))
reclaimed_alloc=$((before_alloc - after_alloc))
{
    printf 'before_free_bytes=%s\n' "$before_free"
    printf 'after_free_bytes=%s\n' "$after_free"
    printf 'free_space_delta_bytes=%s\n' "$reclaimed_free"
    printf 'before_blockfile_allocated_bytes=%s\n' "$before_alloc"
    printf 'after_blockfile_allocated_bytes=%s\n' "$after_alloc"
    printf 'blockfile_allocation_delta_bytes=%s\n' "$reclaimed_alloc"
    printf 'minimum_required_reclaim_bytes=%s\n' "$MIN_RECLAIM_BYTES"
} | tee "$RUN_ROOT/capacity-result.txt"
(( reclaimed_free >= MIN_RECLAIM_BYTES )) || fail "free-space reclamation was below the required boundary"
(( reclaimed_alloc >= MIN_RECLAIM_BYTES )) || fail "blockfile allocation did not fall by the required boundary"

"$GATE" post-completed-image-cleanup | tee "$RUN_ROOT/host-gate-after.txt"
rg -q '^host_safety=ready$' "$RUN_ROOT/host-gate-after.txt" || fail "post-cleanup host gate is not ready"

find "$RUN_ROOT" -maxdepth 1 -type f ! -name cleanup.log ! -name SHA256SUMS \
    -print0 | sort -z | xargs -0 sha256sum >"$RUN_ROOT/SHA256SUMS"
printf 'cleanup_status=passed\nrun_root=%s\n' "$RUN_ROOT"
