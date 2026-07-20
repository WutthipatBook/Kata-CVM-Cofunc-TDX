#!/usr/bin/env bash
set -Eeuo pipefail

CNI_CONFIG=${CNI_CONFIG:-/etc/cni/net.d/00-cofunc-tdx.conflist}
LEGACY_CNI_CONFIG=${LEGACY_CNI_CONFIG:-/etc/cni/net.d/10-cofunc-tdx.conflist}
CNI_BIN_DIR=${CNI_BIN_DIR:-/opt/cni/bin}
BRIDGE=${BRIDGE:-cofunc0}
SUBNET=${SUBNET:-172.16.0.0/16}
GATEWAY=${GATEWAY:-172.16.0.1}
RANGE_START=${RANGE_START:-172.16.1.1}
RANGE_END=${RANGE_END:-172.16.254.254}
BACKUP_DIR=${BACKUP_DIR:-/home/booklyn/BookArchive/KataTdxBackups}

usage() {
    cat <<'EOF'
Usage:
  sudo prepare_kata_tdx_cni_network.sh --check
  sudo prepare_kata_tdx_cni_network.sh --apply
  sudo prepare_kata_tdx_cni_network.sh --remove

--apply installs a dedicated CNI bridge configuration for Kata FunctionBench
workloads. It does not restart containerd. The cofunc0 bridge is created when
a subsequent `ctr run --cni` task starts. It migrates the helper-created
10-cofunc-tdx.conflist to this earlier-sorting configuration name.

--remove removes only this helper's CNI configuration file. It does not remove
a live bridge or terminate workloads; use it only after CNI tasks are gone.
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

need_root() {
    (( EUID == 0 )) || die "run this command with sudo"
}

check_plugins() {
    local plugin
    for plugin in bridge host-local; do
        [[ -x "$CNI_BIN_DIR/$plugin" ]] || die "missing CNI plugin: $CNI_BIN_DIR/$plugin"
    done
}

check() {
    check_plugins
    echo "cni_config=$CNI_CONFIG"
    echo "cni_bin_dir=$CNI_BIN_DIR"
    echo "bridge=$BRIDGE"
    echo "subnet=$SUBNET"
    echo "gateway=$GATEWAY"
    echo "range_start=$RANGE_START"
    echo "range_end=$RANGE_END"
    if [[ -f "$CNI_CONFIG" ]]; then
        echo "cni_config_status=present"
        sed -n '1,220p' "$CNI_CONFIG"
    else
        echo "cni_config_status=missing"
    fi
    ip -br address show dev "$BRIDGE" 2>/dev/null || true
}

apply() {
    local tmp legacy_backup=""

    check_plugins
    [[ ! -e "$CNI_CONFIG" ]] || die "refusing to overwrite existing config: $CNI_CONFIG"
    mkdir -p "$(dirname "$CNI_CONFIG")" "$BACKUP_DIR"
    if [[ "$LEGACY_CNI_CONFIG" != "$CNI_CONFIG" && -f "$LEGACY_CNI_CONFIG" ]]; then
        legacy_backup="$BACKUP_DIR/$(basename "$LEGACY_CNI_CONFIG").pre-cni-order.$(date -u +%Y%m%d_%H%M%S)"
        cp "$LEGACY_CNI_CONFIG" "$legacy_backup"
    fi
    tmp=$(mktemp)

    python3 - "$tmp" "$BRIDGE" "$SUBNET" "$GATEWAY" "$RANGE_START" "$RANGE_END" <<'PY'
import json
import sys

path, bridge, subnet, gateway, range_start, range_end = sys.argv[1:]
config = {
    "cniVersion": "1.0.0",
    "name": "cofunc-tdx",
    "plugins": [
        {
            "type": "bridge",
            "bridge": bridge,
            "isGateway": True,
            "hairpinMode": True,
            "ipMasq": False,
            "ipam": {
                "type": "host-local",
                "ranges": [[{
                    "subnet": subnet,
                    "rangeStart": range_start,
                    "rangeEnd": range_end,
                    "gateway": gateway,
                }]],
            },
        },
    ],
}
with open(path, "w", encoding="utf-8") as stream:
    json.dump(config, stream, indent=2)
    stream.write("\n")
PY

    install -m 0644 "$tmp" "$CNI_CONFIG"
    rm -f "$tmp"
    if [[ -n "$legacy_backup" ]]; then
        rm -f "$LEGACY_CNI_CONFIG"
        echo "migrated legacy CNI config; backup=$legacy_backup"
    fi
    echo "installed CNI config: $CNI_CONFIG"
    check
}

remove() {
    [[ -f "$CNI_CONFIG" ]] || die "CNI config does not exist: $CNI_CONFIG"
    rm -f "$CNI_CONFIG"
    echo "removed CNI config: $CNI_CONFIG"
    check
}

main() {
    case ${1:-} in
        --check)
            need_root
            check
            ;;
        --apply)
            need_root
            apply
            ;;
        --remove)
            need_root
            remove
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
