#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINERD_CONFIG=${CONTAINERD_CONFIG:-/etc/containerd/config.toml}
BLOCK_ROOT=${BLOCK_ROOT:-/Serverless/containerd/data/kata-blockfile}
SCRATCH_FILE=${SCRATCH_FILE:-$BLOCK_ROOT/scratch-2g.ext4}
SCRATCH_SIZE=${SCRATCH_SIZE:-2G}
CANONICAL_SCRATCH=${CANONICAL_SCRATCH:-$BLOCK_ROOT/scratch}
RECREATE_SCRATCH=${RECREATE_SCRATCH:-true}
BACKUP_DIR=${BACKUP_DIR:-/home/booklyn/BookArchive/KataTdxBackups}
CONFIG_BACKUP=

usage() {
    cat <<'EOF'
Usage:
  sudo prepare_kata_tdx_blockfile_snapshotter.sh --check
  sudo prepare_kata_tdx_blockfile_snapshotter.sh --inspect
  sudo prepare_kata_tdx_blockfile_snapshotter.sh --apply
  sudo prepare_kata_tdx_blockfile_snapshotter.sh --rollback <config-backup>

--apply backs up /etc/containerd/config.toml, configures the built-in blockfile
snapshotter, creates an ext4 scratch image when absent, regenerates the
snapshotter's canonical scratch image, and restarts containerd. This can
interrupt running containers. It does not reboot the host.

--inspect is read-only. It additionally lists the retained blockfile images and
the containerd snapshot metadata, which is useful after an image import failure.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

need_root() {
    (( EUID == 0 )) || die "run this command with sudo"
}

plugin_status() {
    /usr/bin/ctr plugins ls | awk \
        '$1 == "io.containerd.snapshotter.v1" && $2 == "blockfile" { print $4 }'
}

check() {
    [[ -r "$CONTAINERD_CONFIG" ]] || die "missing containerd config: $CONTAINERD_CONFIG"

    echo "containerd=$(/usr/bin/containerd --version)"
    echo "config=$CONTAINERD_CONFIG"
    echo "block_root=$BLOCK_ROOT"
    echo "scratch_file=$SCRATCH_FILE"
    if [[ -e "$SCRATCH_FILE" ]]; then
        echo "scratch_size_bytes=$(stat -c '%s' "$SCRATCH_FILE")"
        /usr/sbin/dumpe2fs -h "$SCRATCH_FILE" 2>/dev/null | awk -F: '
            /Block count|Block size|Inode count|Free blocks|Free inodes/ {
                label = $1
                gsub(/[[:space:]]+/, "_", label)
                gsub(/^[[:space:]]+/, "", $2)
                print "scratch_" tolower(label) "=" $2
            }
        '
    else
        echo "scratch_status=missing"
    fi
    echo "canonical_scratch_file=$CANONICAL_SCRATCH"
    if [[ -e "$CANONICAL_SCRATCH" ]]; then
        echo "canonical_scratch_size_bytes=$(stat -c '%s' "$CANONICAL_SCRATCH")"
    else
        echo "canonical_scratch_status=missing"
    fi
    echo "plugin_status=$(plugin_status || true)"
    rg -n -A6 '^  \[plugins\."io\.containerd\.snapshotter\.v1\.blockfile"\]' \
        "$CONTAINERD_CONFIG" || true
}

inspect() {
    check
    echo "blockfile_files_begin (logical_bytes allocated_512b_blocks path)"
    find "$BLOCK_ROOT" -xdev -type f -printf '%s\t%b\t%p\n' | sort -n
    echo "blockfile_files_end"
    echo "blockfile_snapshots_begin"
    /usr/bin/ctr -n default snapshots --snapshotter blockfile ls || true
    echo "blockfile_snapshots_end"
}

configure_blockfile() {
    local tmp

    case "$RECREATE_SCRATCH" in
        true|false) ;;
        *) die "RECREATE_SCRATCH must be true or false" ;;
    esac

    tmp=$(mktemp)
    mkdir -p "$BACKUP_DIR"
    CONFIG_BACKUP="$BACKUP_DIR/containerd-config.pre-kata-tdx-blockfile.$(date -u +%Y%m%d_%H%M%S).toml"

    cp "$CONTAINERD_CONFIG" "$CONFIG_BACKUP"
    cp "$CONTAINERD_CONFIG" "$tmp"

    python3 - "$tmp" "$BLOCK_ROOT" "$SCRATCH_FILE" "$RECREATE_SCRATCH" <<'PY'
import re
import sys

path, root_path, scratch_file, recreate_scratch = sys.argv[1:]
text = open(path, encoding="utf-8").read()
section = '  [plugins."io.containerd.snapshotter.v1.blockfile"]'
replacement = f'''{section}
    fs_type = "ext4"
    mount_options = []
    root_path = "{root_path}"
    scratch_file = "{scratch_file}"
    recreate_scratch = {recreate_scratch}
'''
pattern = re.compile(
    r'(?ms)^  \[plugins\."io\.containerd\.snapshotter\.v1\.blockfile"\]\n.*?(?=^  \[plugins\.|^\[|\Z)'
)
if not pattern.search(text):
    raise SystemExit("blockfile snapshotter section not found")
open(path, "w", encoding="utf-8").write(pattern.sub(replacement, text, count=1))
PY

    install -m 0644 "$tmp" "$CONTAINERD_CONFIG"
    rm -f "$tmp"
    echo "config_backup=$CONFIG_BACKUP"
}

create_scratch() {
    mkdir -p "$BLOCK_ROOT"
    if [[ -e "$SCRATCH_FILE" ]]; then
        echo "using existing scratch file: $SCRATCH_FILE"
        return
    fi

    truncate -s "$SCRATCH_SIZE" "$SCRATCH_FILE"
    mkfs.ext4 -F "$SCRATCH_FILE" >/dev/null
    echo "created ext4 scratch file: $SCRATCH_FILE ($SCRATCH_SIZE)"
}

apply() {
    local status

    [[ -r "$CONTAINERD_CONFIG" ]] || die "missing containerd config: $CONTAINERD_CONFIG"
    create_scratch
    configure_blockfile

    if ! systemctl restart containerd; then
        cp "$CONFIG_BACKUP" "$CONTAINERD_CONFIG"
        systemctl restart containerd || true
        die "containerd restart failed; restored $CONFIG_BACKUP"
    fi
    status=$(plugin_status || true)
    if [[ "$status" != ok ]]; then
        cp "$CONFIG_BACKUP" "$CONTAINERD_CONFIG"
        systemctl restart containerd || true
        die "blockfile plugin is not ready (status: ${status:-missing}); restored $CONFIG_BACKUP"
    fi
    echo "blockfile snapshotter is ready"
    check
}

rollback() {
    local backup=${1:-}

    [[ -n "$backup" ]] || die "--rollback requires a config backup path"
    [[ -f "$backup" ]] || die "backup does not exist: $backup"
    cp "$backup" "$CONTAINERD_CONFIG"
    systemctl restart containerd
    echo "restored containerd config from $backup"
    check
}

main() {
    case ${1:-} in
        --check)
            need_root
            check
            ;;
        --inspect)
            need_root
            inspect
            ;;
        --apply)
            need_root
            apply
            ;;
        --rollback)
            need_root
            shift
            rollback "${1:-}"
            ;;
        -h|--help)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
