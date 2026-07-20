#!/usr/bin/env bash
set -euo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
CONTAINERD_CONFIG=${CONTAINERD_CONFIG:-/etc/containerd/config.toml}
SOURCE_KATA_CONFIG=${SOURCE_KATA_CONFIG:-$BUNDLE/configs/configuration-qemu-tdx-artifact-qemu7-blockroot-normalmem.toml}
DEST_KATA_CONFIG=${DEST_KATA_CONFIG:-/etc/kata-containers/configuration-qemu-tdx-blockroot.toml}
RUNTIME_NAME=${RUNTIME_NAME:-kata-qemu-tdx}
SNAPSHOTTER=${SNAPSHOTTER:-blockfile}
BACKUP_DIR=${BACKUP_DIR:-/home/booklyn/BookArchive/KataTdxBackups}

usage() {
    cat <<'EOF'
Usage: prepare_kata_tdx_cri_blockroot.sh --plan|--apply

--plan   Show the CRI runtime changes without modifying the host.
--apply  Back up the files, install the dedicated Kata config, update only the
         kata-qemu-tdx CRI runtime, and restart containerd.
EOF
}

[[ $# -eq 1 ]] || { usage >&2; exit 2; }
mode=$1
case "$mode" in
    --plan|--apply) ;;
    *) usage >&2; exit 2 ;;
esac

[[ -r "$CONTAINERD_CONFIG" ]] || { echo "missing containerd config: $CONTAINERD_CONFIG" >&2; exit 1; }
[[ -r "$SOURCE_KATA_CONFIG" ]] || { echo "missing Kata config: $SOURCE_KATA_CONFIG" >&2; exit 1; }

runtime_header="[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.${RUNTIME_NAME}]"
options_header="[plugins.\"io.containerd.grpc.v1.cri\".containerd.runtimes.${RUNTIME_NAME}.options]"

rendered=$(mktemp)
trap 'rm -f "$rendered"' EXIT

awk \
    -v runtime_header="$runtime_header" \
    -v options_header="$options_header" \
    -v snapshotter="$SNAPSHOTTER" \
    -v config_path="$DEST_KATA_CONFIG" '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }
    function leave_runtime() {
        if (in_runtime && !snapshotter_seen) {
            print "          snapshotter = \"" snapshotter "\""
            snapshotter_seen = 1
        }
        in_runtime = 0
    }
    trim($0) == runtime_header {
        runtime_seen = 1
        in_runtime = 1
        snapshotter_seen = 0
        print
        next
    }
    trim($0) == options_header {
        if (in_runtime && !snapshotter_seen) {
            print "          snapshotter = \"" snapshotter "\""
            snapshotter_seen = 1
        }
        in_runtime = 0
        in_options = 1
        options_seen = 1
        print
        next
    }
    /^[[:space:]]*\[/ {
        leave_runtime()
        in_options = 0
    }
    in_runtime && /^[[:space:]]*snapshotter[[:space:]]*=/ {
        print "          snapshotter = \"" snapshotter "\""
        snapshotter_seen = 1
        next
    }
    in_options && /^[[:space:]]*ConfigPath[[:space:]]*=/ {
        print "            ConfigPath = \"" config_path "\""
        config_seen = 1
        next
    }
    { print }
    END {
        leave_runtime()
        if (!runtime_seen || !options_seen || !config_seen) {
            exit 42
        }
    }
' "$CONTAINERD_CONFIG" >"$rendered" || {
    echo "could not locate the $RUNTIME_NAME CRI runtime and ConfigPath in $CONTAINERD_CONFIG" >&2
    exit 1
}

if cmp -s "$CONTAINERD_CONFIG" "$rendered" && cmp -s "$SOURCE_KATA_CONFIG" "$DEST_KATA_CONFIG" 2>/dev/null; then
    echo "CRI Kata-TDX block-rootfs configuration is already current"
    exit 0
fi

echo "containerd_config=$CONTAINERD_CONFIG"
echo "runtime_name=$RUNTIME_NAME"
echo "runtime_snapshotter=$SNAPSHOTTER"
echo "runtime_config_path=$DEST_KATA_CONFIG"
echo "source_kata_config=$SOURCE_KATA_CONFIG"

if [[ "$mode" == "--plan" ]]; then
    echo "plan only; no files or services changed"
    exit 0
fi

timestamp=$(date -u +%Y%m%d_%H%M%S)
backup="$BACKUP_DIR/containerd-cri-kata-tdx-blockroot.$timestamp"
mkdir -p "$backup"
sudo cp -a "$CONTAINERD_CONFIG" "$backup/config.toml"
if sudo test -e "$DEST_KATA_CONFIG"; then
    sudo cp -a "$DEST_KATA_CONFIG" "$backup/$(basename "$DEST_KATA_CONFIG")"
fi

sudo install -o root -g root -m 0644 "$SOURCE_KATA_CONFIG" "$DEST_KATA_CONFIG"
sudo install -o root -g root -m 0644 "$rendered" "$CONTAINERD_CONFIG"

if ! sudo systemctl restart containerd; then
    sudo install -o root -g root -m 0644 "$backup/config.toml" "$CONTAINERD_CONFIG"
    sudo systemctl restart containerd || true
    echo "containerd restart failed; restored $CONTAINERD_CONFIG from $backup" >&2
    exit 1
fi

echo "backup_dir=$backup"
sudo ctr plugins ls | awk '$2 == "io.containerd.snapshotter.v1" && $3 == "blockfile" { print "blockfile_plugin_status=" $4 }'
sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock info >/dev/null
echo "CRI Kata-TDX block-rootfs configuration is ready"
