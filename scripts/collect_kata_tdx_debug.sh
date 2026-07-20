#!/usr/bin/env bash
set -euo pipefail

OUT=${OUT:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_debug_collect_$(date -u +%Y%m%d_%H%M%S)}
SINCE=${SINCE:-"30 minutes ago"}
KATA_CONFIG=${KATA_CONFIG:-/home/booklyn/cofunc-tdx/configs/configuration-qemu-tdx-debug-virtiofs.toml}
SUDO=()
if (( EUID != 0 )) && sudo -n true 2>/dev/null; then
    SUDO=(sudo)
fi

mkdir -p "$OUT"

run_capture() {
    local name=$1
    shift
    {
        printf '$'
        printf ' %q' "$@"
        printf '\n\n'
        "$@"
    } >"$OUT/$name" 2>&1 || true
}

run_capture ps.txt ps -ef
run_capture devices.txt "${SUDO[@]}" ls -l /dev/kvm /dev/vhost-vsock /dev/vsock
run_capture modules.txt lsmod
run_capture kata-env.txt "${SUDO[@]}" /opt/kata/bin/kata-runtime --kata-config "$KATA_CONFIG" env
run_capture kata-check.txt "${SUDO[@]}" /opt/kata/bin/kata-runtime --kata-config "$KATA_CONFIG" check --verbose --no-network-checks
run_capture ctr-tasks.txt "${SUDO[@]}" ctr -n default tasks ls
run_capture ctr-containers.txt "${SUDO[@]}" ctr -n default containers ls
run_capture ctr-images.txt "${SUDO[@]}" ctr -n default images ls
run_capture containerd-journal.txt "${SUDO[@]}" journalctl -u containerd --since "$SINCE" --no-pager
run_capture kata-journal.txt "${SUDO[@]}" journalctl --since "$SINCE" --no-pager
run_capture run-kata-tree.txt sh -c "ps -ef | grep -E 'kata|qemu|virtiofs|containerd|ctr' | grep -v grep"
run_capture run-dirs.txt "${SUDO[@]}" find /run/kata-containers /run/vc /run/containerd -maxdepth 6 -printf '%M %u %g %s %TY-%Tm-%Td %TH:%TM:%TS %p\n'

if [[ -n "${KATA_QEMU_WRAPPER_LOG:-}" && -f "$KATA_QEMU_WRAPPER_LOG" ]]; then
    cp "$KATA_QEMU_WRAPPER_LOG" "$OUT/qemu-wrapper.log" || true
fi
for wrapper_log in /tmp/kata-qemu-tdx-oldabi-wrapper*.log /tmp/kata-qemu-tdx-oldabi-qemu*.log; do
    [[ -f "$wrapper_log" ]] || continue
    cp "$wrapper_log" "$OUT/$(basename "$wrapper_log")" || true
done

echo "$OUT"
