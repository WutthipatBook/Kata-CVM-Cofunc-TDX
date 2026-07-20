#!/usr/bin/env bash
set -euo pipefail

KATA_RUNTIME_NAME=${KATA_RUNTIME_NAME:-kata-qemu-tdx}
KATA_RUNTIME_TYPE=${KATA_RUNTIME_TYPE:-io.containerd.${KATA_RUNTIME_NAME}.v2}
KATA_CONFIG=${KATA_CONFIG:-/etc/kata-containers/configuration-qemu-tdx.toml}
KATA_OPT_DIR=${KATA_OPT_DIR:-/opt/kata}
KATA_TARBALL=${KATA_TARBALL:-/home/booklyn/BookArchive/Deps/kata-static-3.32.0-amd64.tar.zst}
TDX_QEMU=${TDX_QEMU:-/opt/kata/bin/qemu-system-x86_64}
TDX_FIRMWARE=${TDX_FIRMWARE:-/opt/kata/share/ovmf/OVMF.inteltdx.fd}
VIRTIOFSD=${VIRTIOFSD:-/opt/kata/libexec/virtiofsd}
CONTAINERD_CONFIG=${CONTAINERD_CONFIG:-/etc/containerd/config.toml}

status=0

check_file() {
    local label=$1
    local path=$2
    if [[ -e "$path" ]]; then
        printf "OK   %-28s %s\n" "$label" "$path"
    else
        printf "MISS %-28s %s\n" "$label" "$path"
        status=1
    fi
}

check_cmd() {
    local label=$1
    local cmd=$2
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "OK   %-28s %s\n" "$label" "$(command -v "$cmd")"
    else
        printf "MISS %-28s %s\n" "$label" "$cmd"
        status=1
    fi
}

check_rg() {
    local label=$1
    local pattern=$2
    local file=$3
    if [[ -r "$file" ]] && rg -q "$pattern" "$file"; then
        printf "OK   %-28s %s\n" "$label" "$file"
    else
        printf "MISS %-28s %s\n" "$label" "$file"
        status=1
    fi
}

check_fixed() {
    local label=$1
    local text=$2
    local file=$3
    if [[ -r "$file" ]] && rg -F -q "$text" "$file"; then
        printf "OK   %-28s %s\n" "$label" "$file"
    else
        printf "MISS %-28s %s\n" "$label" "$file"
        status=1
    fi
}

printf "Kata-TDX preflight\n"
printf "runtime_name=%s\n" "$KATA_RUNTIME_NAME"
printf "runtime_type=%s\n" "$KATA_RUNTIME_TYPE"
printf "\n"

check_cmd "containerd" containerd
check_cmd "ctr" ctr
check_cmd "docker" docker
check_cmd "qemu-system-x86_64" qemu-system-x86_64
check_cmd "zstd" zstd
check_cmd "jq" jq
check_file "host /dev/kvm" /dev/kvm
check_file "TDX QEMU" "$TDX_QEMU"
check_file "TDVF firmware" "$TDX_FIRMWARE"
check_file "virtiofsd" "$VIRTIOFSD"
check_file "Kata opt dir" "$KATA_OPT_DIR"
check_file "Kata config" "$KATA_CONFIG"
check_file "containerd config" "$CONTAINERD_CONFIG"
check_file "static tarball cache" "$KATA_TARBALL"

shim_path=$(command -v "containerd-shim-${KATA_RUNTIME_NAME}-v2" 2>/dev/null || true)
if [[ -n "$shim_path" ]]; then
    printf "OK   %-28s %s\n" "Kata TDX shim" "$shim_path"
else
    printf "MISS %-28s %s\n" "Kata TDX shim" "containerd-shim-${KATA_RUNTIME_NAME}-v2"
    status=1
fi

if [[ -r "$KATA_CONFIG" ]]; then
    check_rg "config confidential" "^confidential_guest = true" "$KATA_CONFIG"
    check_fixed "config TDX QEMU" "path = \"$TDX_QEMU\"" "$KATA_CONFIG"
    check_fixed "config TDVF" "firmware = \"$TDX_FIRMWARE\"" "$KATA_CONFIG"
fi

if [[ -r "$CONTAINERD_CONFIG" ]]; then
    check_rg "containerd runtime" "$KATA_RUNTIME_NAME" "$CONTAINERD_CONFIG"
    check_rg "containerd type" "$KATA_RUNTIME_TYPE" "$CONTAINERD_CONFIG"
fi

printf "\n"
if sudo -n true 2>/dev/null; then
    if sudo ctr version >/dev/null 2>&1; then
        printf "OK   %-28s %s\n" "ctr sudo access" "containerd socket reachable"
    else
        printf "MISS %-28s %s\n" "ctr sudo access" "containerd socket not reachable"
        status=1
    fi
else
    printf "WARN %-28s %s\n" "sudo credentials" "run sudo -v before install/run"
fi

printf "\n"
if (( status == 0 )); then
    printf "preflight=ready\n"
else
    printf "preflight=missing-pieces\n"
fi
exit "$status"
