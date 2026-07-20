#!/usr/bin/env bash
set -euo pipefail

KATA_VERSION=${KATA_VERSION:-3.32.0}
KATA_ARCH=${KATA_ARCH:-amd64}
KATA_RUNTIME_NAME=${KATA_RUNTIME_NAME:-kata-qemu-tdx}
KATA_RUNTIME_TYPE=${KATA_RUNTIME_TYPE:-io.containerd.${KATA_RUNTIME_NAME}.v2}
KATA_CONFIG=${KATA_CONFIG:-/etc/kata-containers/configuration-qemu-tdx.toml}
KATA_OPT_DIR=${KATA_OPT_DIR:-/opt/kata}
KATA_TARBALL=${KATA_TARBALL:-/home/booklyn/BookArchive/Deps/kata-static-${KATA_VERSION}-${KATA_ARCH}.tar.zst}
KATA_DOWNLOAD_URL=${KATA_DOWNLOAD_URL:-}
TDX_QEMU=${TDX_QEMU:-}
TDX_FIRMWARE=${TDX_FIRMWARE:-}
KATA_KERNEL=${KATA_KERNEL:-}
KATA_IMAGE=${KATA_IMAGE:-}
TDX_DEFAULT_MEMORY=${TDX_DEFAULT_MEMORY:-2048}
TDX_DEFAULT_VCPUS=${TDX_DEFAULT_VCPUS:-1}
VIRTIOFSD=${VIRTIOFSD:-}
CONTAINERD_CONFIG=${CONTAINERD_CONFIG:-/etc/containerd/config.toml}
RESTART_CONTAINERD=${RESTART_CONTAINERD:-1}
DOWNLOAD_KATA=${DOWNLOAD_KATA:-1}

need_sudo() {
    if ! sudo -n true 2>/dev/null; then
        cat >&2 <<'EOF'
sudo credentials are not cached.
Run `sudo -v` in a terminal, then rerun this script.
EOF
        exit 1
    fi
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_file() {
    local path=$1
    [[ -e "$path" ]] || die "missing required file: $path"
}

discover_download_url() {
    if [[ -n "$KATA_DOWNLOAD_URL" ]]; then
        printf "%s\n" "$KATA_DOWNLOAD_URL"
        return
    fi

    python3 - "$KATA_VERSION" "$KATA_ARCH" <<'PY'
import json
import sys
import urllib.request

version, arch = sys.argv[1], sys.argv[2]
url = f"https://api.github.com/repos/kata-containers/kata-containers/releases/tags/{version}"
with urllib.request.urlopen(url, timeout=30) as resp:
    release = json.load(resp)

want = f"kata-static-{version}-{arch}.tar.zst"
for asset in release.get("assets", []):
    if asset.get("name") == want:
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit(f"asset not found in release {version}: {want}")
PY
}

download_tarball() {
    if [[ -e "$KATA_TARBALL" ]]; then
        return
    fi
    [[ "$DOWNLOAD_KATA" == "1" ]] || die "KATA_TARBALL does not exist and DOWNLOAD_KATA=0: $KATA_TARBALL"

    local url
    url=$(discover_download_url)
    mkdir -p "$(dirname "$KATA_TARBALL")"
    echo "download $url"
    curl -fL --retry 3 --retry-delay 2 -o "$KATA_TARBALL" "$url"
}

find_one() {
    local root=$1
    shift
    find "$root" "$@" 2>/dev/null | head -n 1
}

toml_value() {
    local file=$1
    local section=$2
    local key=$3
    python3 - "$file" "$section" "$key" <<'PY'
import re
import sys

path, section, key = sys.argv[1:]
current = ""
for raw in open(path, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    sec = re.match(r"^\[([^]]+)\]$", line)
    if sec:
        current = sec.group(1)
        continue
    if current == section:
        m = re.match(rf"^{re.escape(key)}\s*=\s*\"([^\"]*)\"", line)
        if m:
            print(m.group(1))
            break
PY
}

patch_kata_config() {
    local src_config=$1
    local kernel=$2
    local image=$3
    local tmp
    tmp=$(mktemp)

    python3 - "$src_config" "$tmp" "$TDX_QEMU" "$kernel" "$image" "$TDX_FIRMWARE" "$VIRTIOFSD" "$TDX_DEFAULT_MEMORY" "$TDX_DEFAULT_VCPUS" <<'PY'
import re
import sys

src, dst, qemu, kernel, image, firmware, virtiofsd, default_memory, default_vcpus = sys.argv[1:]

setters = {
    "path": f'path = "{qemu}"',
    "kernel": f'kernel = "{kernel}"',
    "image": f'image = "{image}"',
    "machine_type": 'machine_type = "q35"',
    "confidential_guest": "confidential_guest = true",
    "firmware": f'firmware = "{firmware}"',
    "firmware_volume": 'firmware_volume = ""',
    "default_vcpus": f"default_vcpus = {default_vcpus}",
    "default_memory": f"default_memory = {default_memory}",
    "valid_hypervisor_paths": f'valid_hypervisor_paths = ["{qemu}", "/opt/kata/bin/qemu-system-x86_64"]',
    "entropy_source": 'entropy_source= "/dev/urandom"',
}

if virtiofsd:
    setters["virtio_fs_daemon"] = f'virtio_fs_daemon = "{virtiofsd}"'
    setters["valid_virtio_fs_daemon_paths"] = f'valid_virtio_fs_daemon_paths = ["{virtiofsd}", "/opt/kata/libexec/virtiofsd", "/usr/lib/qemu/virtiofsd"]'

current_section = ""
out = []
seen = set()
for raw in open(src, encoding="utf-8"):
    line = raw.rstrip("\n")
    sec = re.match(r"^\[([^]]+)\]\s*$", line)
    if sec:
        current_section = sec.group(1)
    if current_section == "hypervisor.qemu":
        m = re.match(r"^([A-Za-z0-9_]+)\s*=", line)
        if m and m.group(1) in setters:
            key = m.group(1)
            out.append(setters[key])
            seen.add(key)
            continue
    out.append(line)

if "hypervisor.qemu" not in "".join(out):
    raise SystemExit("source config does not contain [hypervisor.qemu]")

text = "\n".join(out) + "\n"
open(dst, "w", encoding="utf-8").write(text)
PY

    sudo install -D -m 0644 "$tmp" "$KATA_CONFIG"
    rm -f "$tmp"
}

patch_containerd_config() {
    local tmp backup
    tmp=$(mktemp)
    backup="${CONTAINERD_CONFIG}.pre-kata-tdx.$(date -u +%Y%m%d_%H%M%S)"

    sudo cp "$CONTAINERD_CONFIG" "$backup"
    sudo cp "$CONTAINERD_CONFIG" "$tmp"

    python3 - "$tmp" "$KATA_RUNTIME_NAME" "$KATA_RUNTIME_TYPE" "$KATA_CONFIG" <<'PY'
import re
import sys

path, runtime_name, runtime_type, config_path = sys.argv[1:]
text = open(path, encoding="utf-8").read()

stanza = f'''
        [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.{runtime_name}]
          runtime_type = "{runtime_type}"
          privileged_without_host_devices = false
          pod_annotations = ["io.katacontainers.*"]
          container_annotations = ["io.katacontainers.*"]

          [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.{runtime_name}.options]
            ConfigPath = "{config_path}"
'''

pattern = re.compile(
    r'(?ms)^        \[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.'
    + re.escape(runtime_name)
    + r'\].*?(?=^        \[plugins\."io\.containerd\.grpc\.v1\.cri"\.containerd\.runtimes\.|^    \[|^  \[|^\[|\Z)'
)
if pattern.search(text):
    text = pattern.sub(stanza.lstrip("\n"), text)
else:
    anchor = '      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes]\n'
    if anchor not in text:
        raise SystemExit("containerd CRI runtimes anchor not found")
    text = text.replace(anchor, anchor + stanza, 1)

open(path, "w", encoding="utf-8").write(text)
PY

    sudo install -m 0644 "$tmp" "$CONTAINERD_CONFIG"
    rm -f "$tmp"
    echo "containerd backup: $backup"
}

need_sudo
require_file "$CONTAINERD_CONFIG"
download_tarball
require_file "$KATA_TARBALL"

echo "extract $KATA_TARBALL -> /"
sudo tar --zstd -xf "$KATA_TARBALL" -C /

shim=$(find_one "$KATA_OPT_DIR/bin" -type f \( -name containerd-shim-kata-qemu-v2 -o -name containerd-shim-kata-v2 \))
[[ -n "$shim" ]] || die "no Kata containerd shim found under $KATA_OPT_DIR/bin"
sudo ln -sf "$shim" "/usr/local/bin/containerd-shim-${KATA_RUNTIME_NAME}-v2"

src_config=$(find_one "$KATA_OPT_DIR" -type f -name configuration-qemu-tdx.toml)
if [[ -z "$src_config" ]]; then
    src_config=$(find_one "$KATA_OPT_DIR" -type f -name configuration-qemu.toml)
fi
[[ -n "$src_config" ]] || die "no generated Kata qemu config found under $KATA_OPT_DIR"

src_qemu=$(toml_value "$src_config" "hypervisor.qemu" "path")
src_firmware=$(toml_value "$src_config" "hypervisor.qemu" "firmware")
src_kernel=$(toml_value "$src_config" "hypervisor.qemu" "kernel")
src_image=$(toml_value "$src_config" "hypervisor.qemu" "image")
src_virtiofsd=$(toml_value "$src_config" "hypervisor.qemu" "virtio_fs_daemon")

TDX_QEMU=${TDX_QEMU:-$src_qemu}
TDX_FIRMWARE=${TDX_FIRMWARE:-$src_firmware}
VIRTIOFSD=${VIRTIOFSD:-$src_virtiofsd}
kernel=${KATA_KERNEL:-$src_kernel}
image=${KATA_IMAGE:-$src_image}

if [[ -z "$kernel" ]]; then
    kernel=$(find_one "$KATA_OPT_DIR/share/kata-containers" -type f \( -name 'vmlinuz.container' -o -name 'vmlinuz-*' \))
fi
if [[ -z "$image" ]]; then
    image=$(find_one "$KATA_OPT_DIR/share/kata-containers" -type f \( -name 'kata-containers-confidential.img' -o -name '*confidential*.img' -o -name 'kata-containers.img' \))
fi

require_file "$TDX_QEMU"
require_file "$TDX_FIRMWARE"
if [[ -n "$VIRTIOFSD" ]]; then
    require_file "$VIRTIOFSD"
fi
[[ -n "$kernel" ]] || die "no Kata guest kernel found under $KATA_OPT_DIR/share/kata-containers"
[[ -n "$image" ]] || die "no Kata guest image found under $KATA_OPT_DIR/share/kata-containers"
require_file "$kernel"
require_file "$image"

echo "shim=$shim"
echo "qemu=$TDX_QEMU"
echo "firmware=$TDX_FIRMWARE"
echo "kernel=$kernel"
echo "image=$image"
echo "source_config=$src_config"

patch_kata_config "$src_config" "$kernel" "$image"
patch_containerd_config

if [[ "$RESTART_CONTAINERD" == "1" ]]; then
    sudo systemctl restart containerd
fi

cat <<EOF
Kata-TDX runtime configured.

runtime_type=$KATA_RUNTIME_TYPE
config=$KATA_CONFIG
shim=/usr/local/bin/containerd-shim-${KATA_RUNTIME_NAME}-v2

Run:
  /home/booklyn/cofunc-tdx/scripts/kata_tdx_preflight.sh
EOF
