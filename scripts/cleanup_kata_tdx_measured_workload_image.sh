#!/usr/bin/env bash
# Remove the three containerd image references created for one successfully
# measured workload. Snapshot/content cleanup remains exclusively containerd's
# responsibility; this script never removes snapshots, content, or leases.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
GATE=${GATE:-$BUNDLE/scripts/kata_tdx_host_safety_gate.sh}
BLOCK_ROOT=${BLOCK_ROOT:-/Serverless/containerd/data/kata-blockfile}
MIN_FREE_BYTES=${MIN_FREE_BYTES:-107374182400}
EVIDENCE_ROOT=${EVIDENCE_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_measured_image_cleanup_$(date -u +%Y%m%d_%H%M%S)}

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

capture_inventory() {
    local label=$1 namespace
    df -B1 /Serverless >"$EVIDENCE_ROOT/df-$label.txt"
    du -B1 -s "$BLOCK_ROOT" >"$EVIDENCE_ROOT/blockfile-du-$label.txt"
    find "$BLOCK_ROOT" -xdev -type f -printf '%s %b %p\n' |
        sort -k3,3 >"$EVIDENCE_ROOT/blockfile-files-$label.txt"
    for namespace in default k8s.io; do
        ctr -n "$namespace" images ls >"$EVIDENCE_ROOT/$namespace-images-$label.txt"
        ctr -n "$namespace" images ls -q | sort -u \
            >"$EVIDENCE_ROOT/$namespace-image-refs-$label.txt"
        ctr -n "$namespace" snapshots --snapshotter blockfile ls \
            >"$EVIDENCE_ROOT/$namespace-snapshots-$label.txt"
        ctr -n "$namespace" leases ls >"$EVIDENCE_ROOT/$namespace-leases-$label.txt"
    done
}

remove_expected_ref() {
    local reference=$1 file=$2 tmp=$3
    awk -v reference="$reference" '$0 != reference' "$file" >"$tmp"
    mv "$tmp" "$file"
}

usage() {
    cat >&2 <<'EOF'
Usage:
  sudo cleanup_kata_tdx_measured_workload_image.sh <validated-measurement-run-root>
EOF
    exit 2
}

(( $# == 1 )) || usage
(( EUID == 0 )) || fail "run this script with sudo"
for command in awk cmp cp ctr date df docker du find mv rg sha256sum sort tail tee tr xargs; do
    need "$command"
done
[[ -x $GATE ]] || fail "missing host safety gate: $GATE"
[[ -d $BLOCK_ROOT ]] || fail "missing blockfile root: $BLOCK_ROOT"
[[ $MIN_FREE_BYTES =~ ^[1-9][0-9]*$ ]] || fail "MIN_FREE_BYTES must be positive"

measurement_root=${1%/}
[[ -d $measurement_root ]] || fail "missing measurement run root: $measurement_root"
[[ -r $measurement_root/harness-result.txt ]] || fail "missing harness result"
[[ -r $measurement_root/harness.sha256 ]] || fail "missing harness hash"
run_env=$measurement_root/prebuild/attempt-001/run-env.txt
[[ -r $run_env ]] || fail "missing prebuild run environment: $run_env"

for expected in 'run_rc=0' 'postflight_gate_rc=0' 'evidence_rc=0'; do
    rg -qx --fixed-strings "$expected" "$measurement_root/harness-result.txt" ||
        fail "measurement is not validated: missing $expected"
done
workload=$(awk -F= '$1 == "workload" { print $2; exit }' "$run_env")
derived_image=$(awk -F= '$1 == "derived_image" { print $2; exit }' "$run_env")
cri_image=$(awk -F= '$1 == "cri_image" { print $2; exit }' "$run_env")
recorded_id=$(awk -F= '$1 == "derived_image_id" { print $2; exit }' "$run_env")
[[ $workload =~ ^(fn|chain)_[A-Za-z0-9_/-]+$ ]] || fail "invalid recorded workload: $workload"
[[ $derived_image == kata-tdx-*:latest ]] || fail "invalid recorded derived image: $derived_image"
[[ $cri_image == docker.io/library/kata-tdx-*:latest ]] || fail "invalid recorded CRI image: $cri_image"
[[ $recorded_id =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid recorded Docker ID: $recorded_id"

docker_id=$(docker image inspect --format '{{.Id}}' "$derived_image")
[[ $docker_id == "$recorded_id" ]] ||
    fail "local Docker recovery image changed: recorded=$recorded_id current=$docker_id"
source_image=$(awk -F= '$1 == "source_image" { print $2; exit }' "$run_env")
docker image inspect "$source_image" >/dev/null

source_ref="${cri_image%:*}:source-${docker_id#sha256:}"
digest_ref=$docker_id
approved_refs=("$cri_image" "$source_ref" "$digest_ref")

mkdir -p "$EVIDENCE_ROOT"
exec > >(tee -a "$EVIDENCE_ROOT/cleanup.log") 2>&1
printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'evidence_root=%s\nmeasurement_root=%s\nworkload=%s\n' \
    "$EVIDENCE_ROOT" "$measurement_root" "$workload"
printf 'derived_image=%s\ndocker_id=%s\n' "$derived_image" "$docker_id"
printf 'cri_image=%s\nsource_ref=%s\ndigest_ref=%s\n' \
    "$cri_image" "$source_ref" "$digest_ref"
sha256sum "$0" >"$EVIDENCE_ROOT/script.sha256"
sha256sum "$measurement_root/harness-result.txt" "$measurement_root/harness.sha256" \
    "$run_env" >"$EVIDENCE_ROOT/measurement-inputs.sha256"

"$GATE" pre-measured-image-cleanup | tee "$EVIDENCE_ROOT/host-gate-before.txt"
rg -q '^host_safety=ready$' "$EVIDENCE_ROOT/host-gate-before.txt" ||
    fail "pre-cleanup host gate is not ready"

target_digest=""
: >"$EVIDENCE_ROOT/approved-images-before.txt"
for reference in "${approved_refs[@]}"; do
    digest=$(image_digest k8s.io "$reference")
    [[ -n $digest ]] || fail "approved reference is absent: $reference"
    if [[ -z $target_digest ]]; then
        target_digest=$digest
    else
        [[ $digest == "$target_digest" ]] ||
            fail "approved references do not resolve to one target digest"
    fi
    printf 'k8s.io %s %s\n' "$reference" "$digest" |
        tee -a "$EVIDENCE_ROOT/approved-images-before.txt"
done

capture_inventory before
cp "$EVIDENCE_ROOT/k8s.io-image-refs-before.txt" \
    "$EVIDENCE_ROOT/k8s.io-image-refs-expected-after.txt"
for reference in "${approved_refs[@]}"; do
    remove_expected_ref "$reference" \
        "$EVIDENCE_ROOT/k8s.io-image-refs-expected-after.txt" \
        "$EVIDENCE_ROOT/k8s.io-image-refs-expected-after.tmp"
done
cp "$EVIDENCE_ROOT/default-image-refs-before.txt" \
    "$EVIDENCE_ROOT/default-image-refs-expected-after.txt"
cp "$EVIDENCE_ROOT/k8s.io-leases-before.txt" "$EVIDENCE_ROOT/k8s.io-leases-expected.txt"
cp "$EVIDENCE_ROOT/default-leases-before.txt" "$EVIDENCE_ROOT/default-leases-expected.txt"

before_free=$(df -B1 --output=avail /Serverless | tail -n 1 | tr -d '[:space:]')
before_alloc=$(du -B1 -s "$BLOCK_ROOT" | awk '{print $1}')
[[ $before_free =~ ^[0-9]+$ && $before_alloc =~ ^[0-9]+$ ]] ||
    fail "could not measure pre-cleanup capacity"

printf 'Removing three approved k8s.io references with synchronous GC\n'
ctr -n k8s.io images rm --sync "${approved_refs[@]}" |
    tee "$EVIDENCE_ROOT/k8s.io-image-removal.txt"

capture_inventory after
for reference in "${approved_refs[@]}"; do
    [[ -z $(image_digest k8s.io "$reference") ]] ||
        fail "removed reference remains: $reference"
done
cmp "$EVIDENCE_ROOT/k8s.io-image-refs-expected-after.txt" \
    "$EVIDENCE_ROOT/k8s.io-image-refs-after.txt" ||
    fail "unexpected k8s.io image-reference change"
cmp "$EVIDENCE_ROOT/default-image-refs-expected-after.txt" \
    "$EVIDENCE_ROOT/default-image-refs-after.txt" ||
    fail "unexpected default image-reference change"
cmp "$EVIDENCE_ROOT/k8s.io-leases-expected.txt" "$EVIDENCE_ROOT/k8s.io-leases-after.txt" ||
    fail "k8s.io lease inventory changed"
cmp "$EVIDENCE_ROOT/default-leases-expected.txt" "$EVIDENCE_ROOT/default-leases-after.txt" ||
    fail "default lease inventory changed"

after_free=$(df -B1 --output=avail /Serverless | tail -n 1 | tr -d '[:space:]')
after_alloc=$(du -B1 -s "$BLOCK_ROOT" | awk '{print $1}')
[[ $after_free =~ ^[0-9]+$ && $after_alloc =~ ^[0-9]+$ ]] ||
    fail "could not measure post-cleanup capacity"
{
    printf 'before_free_bytes=%s\n' "$before_free"
    printf 'after_free_bytes=%s\n' "$after_free"
    printf 'free_space_delta_bytes=%s\n' "$((after_free - before_free))"
    printf 'before_blockfile_allocated_bytes=%s\n' "$before_alloc"
    printf 'after_blockfile_allocated_bytes=%s\n' "$after_alloc"
    printf 'blockfile_allocation_delta_bytes=%s\n' "$((before_alloc - after_alloc))"
    printf 'minimum_post_cleanup_free_bytes=%s\n' "$MIN_FREE_BYTES"
} | tee "$EVIDENCE_ROOT/capacity-result.txt"
(( after_free >= MIN_FREE_BYTES )) || fail "post-cleanup free space is below the safety boundary"

"$GATE" post-measured-image-cleanup | tee "$EVIDENCE_ROOT/host-gate-after.txt"
rg -q '^host_safety=ready$' "$EVIDENCE_ROOT/host-gate-after.txt" ||
    fail "post-cleanup host gate is not ready"

find "$EVIDENCE_ROOT" -maxdepth 1 -type f ! -name cleanup.log ! -name SHA256SUMS \
    -print0 | sort -z | xargs -0 sha256sum >"$EVIDENCE_ROOT/SHA256SUMS"
printf 'cleanup_status=passed\nevidence_root=%s\n' "$EVIDENCE_ROOT"
