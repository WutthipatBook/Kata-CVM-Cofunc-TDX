#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
RUN_DIR="${RUN_DIR:-/home/booklyn/BookArchive/StageBreakdownRuns/kata_tdx_vanilla_smoke_oldabi_qemu7_kata_ovmf_normalmem_ktrace_$STAMP}"
TRACE_ROOT="${TRACE_ROOT:-/sys/kernel/tracing}"
ALT_TRACE_ROOT="/sys/kernel/debug/tracing"
TRACE_EVENT="${KVM_TDX_TRACE_EVENT:-kvm/kvm_tdx_hypercall}"
SMOKE="${SMOKE:-$BUNDLE/scripts/run_kata_tdx_smoke_kata_ovmf_qemu7_normalmem_fwdebug.sh}"

TRACE_READY=0
TRACE=""
EVENT_DIR=""

die() {
	echo "error: $*" >&2
	exit 1
}

sudo_write() {
	local value=$1
	local path=$2
	printf '%s\n' "$value" | sudo tee "$path" >/dev/null
}

find_trace_root() {
	if sudo test -d "$TRACE_ROOT/events"; then
		printf '%s\n' "$TRACE_ROOT"
		return
	fi
	if sudo test -d "$ALT_TRACE_ROOT/events"; then
		printf '%s\n' "$ALT_TRACE_ROOT"
		return
	fi

	if ! sudo test -d "$TRACE_ROOT"; then
		sudo mkdir -p "$TRACE_ROOT"
	fi
	sudo mount -t tracefs nodev "$TRACE_ROOT" 2>/dev/null || true
	if sudo test -d "$TRACE_ROOT/events"; then
		printf '%s\n' "$TRACE_ROOT"
		return
	fi

	die "tracefs is not mounted at $TRACE_ROOT or $ALT_TRACE_ROOT"
}

list_candidate_events() {
	local trace=$1
	sudo find "$trace/events" -maxdepth 3 -type d \
		\( -iname '*tdx*' -o -iname '*hypercall*' \) \
		-print 2>/dev/null | sort
}

copy_qemu_tmp_logs() {
	local dst="$RUN_DIR/qemu-tmp-logs"
	mkdir -p "$dst"
	find /tmp -maxdepth 1 -type f -name 'kata-qemu-tdx-oldabi-*' \
		-newer "$RUN_DIR/.trace-start" -print0 |
		xargs -0 -r cp -p -t "$dst"
}

cleanup_trace() {
	set +e
	if [[ "$TRACE_READY" == 1 ]]; then
		sudo_write 0 "$TRACE/tracing_on"
		sudo_write 0 "$EVENT_DIR/enable"
	fi
}

main() {
	local rc

	[[ -x "$SMOKE" ]] || die "missing smoke runner: $SMOKE"
	if ! sudo -n true 2>/dev/null; then
		die "sudo credentials are not cached; run: sudo -v"
	fi

	mkdir -p "$RUN_DIR"
	touch "$RUN_DIR/.trace-start"

	TRACE="$(find_trace_root)"
	EVENT_DIR="$TRACE/events/$TRACE_EVENT"
	if ! sudo test -d "$EVENT_DIR"; then
		list_candidate_events "$TRACE" >"$RUN_DIR/available-kvm-tdx-events.txt" || true
		die "missing trace event $TRACE_EVENT; candidates saved to $RUN_DIR/available-kvm-tdx-events.txt"
	fi

	{
		echo "run_dir=$RUN_DIR"
		echo "trace_root=$TRACE"
		echo "trace_event=$TRACE_EVENT"
		echo "smoke=$SMOKE"
		echo "started=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	} >"$RUN_DIR/kvm-trace-env.txt"

	trap cleanup_trace EXIT
	sudo_write 0 "$TRACE/tracing_on"
	sudo sh -c ': > "$1"' sh "$TRACE/trace"
	sudo_write 1 "$EVENT_DIR/enable"
	sudo_write 1 "$TRACE/tracing_on"
	TRACE_READY=1

	set +e
	KATA_SMOKE_RUN_DIR="$RUN_DIR" "$SMOKE"
	rc=$?
	set -e

	sudo_write 0 "$TRACE/tracing_on"
	sudo cat "$TRACE/trace" >"$RUN_DIR/kvm-tdx-hypercall.trace"
	sudo cat "$EVENT_DIR/format" >"$RUN_DIR/kvm-tdx-hypercall.format" 2>/dev/null || true
	sudo_write 0 "$EVENT_DIR/enable"
	TRACE_READY=0

	copy_qemu_tmp_logs || true
	echo "rc=$rc" >"$RUN_DIR/kvm-trace-result.txt"
	echo "run_dir=$RUN_DIR"
	return "$rc"
}

main "$@"
