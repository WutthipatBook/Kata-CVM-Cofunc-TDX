#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
BPFTRACE=${BPFTRACE:-/usr/local/bin/bpftrace}
TRACE_PROGRAM=${TRACE_PROGRAM:-$BUNDLE/scripts/kata_tdx_ept_fault_trace.bt}
SIGNAL_SERVER=${SIGNAL_SERVER:-$BUNDLE/scripts/ept_trace_signal_server.py}
TRACE_ROOT=${TRACE_ROOT:-/sys/kernel/tracing}
TRACE_PORT=${TRACE_PORT:-18888}
CNI_GATEWAY=${CNI_GATEWAY:-172.16.0.1}

usage() {
	cat <<'EOF'
Usage: run_ept_trace_around.sh OUTPUT_DIR -- COMMAND [ARG ...]

Runs COMMAND as the invoking user while root bpftrace records aggregate TDX
EPT counts. An authenticated guest signal gates compact per-fault service
records to the measured handler window. Sudo credentials must already be
cached. The caller remains responsible for Kata host-safety gates.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

count_matches() {
	local pattern=$1
	shift
	{ rg --no-filename "$pattern" "$@" 2>/dev/null || true; } | \
		awk 'END { print NR }'
}

count_matches_ci() {
	local pattern=$1
	shift
	{ rg -i --no-filename "$pattern" "$@" 2>/dev/null || true; } | \
		awk 'END { print NR }'
}

trace_pid=""
trace_launcher_pid=""
server_pid=""
server_launcher_pid=""
processes_stopped=0

root_process_alive() {
	local pid=$1
	[[ -n $pid ]] && sudo -n kill -0 "$pid" 2>/dev/null
}

wait_for_root_process_exit() {
	local pid=$1
	for _ in $(seq 1 100); do
		root_process_alive "$pid" || return 0
		sleep 0.1
	done
	return 1
}

stop_processes() {
	(( processes_stopped == 0 )) || return 0
	processes_stopped=1
	[[ -n $trace_pid || ! -s $trace_pidfile ]] || trace_pid=$(<"$trace_pidfile")
	[[ -n $server_pid || ! -s $server_pidfile ]] || server_pid=$(<"$server_pidfile")
	if [[ -n $trace_pid ]]; then
		sudo -n kill -INT "$trace_pid" 2>/dev/null || true
	elif [[ -n $trace_launcher_pid ]]; then
		sudo -n kill -TERM "$trace_launcher_pid" 2>/dev/null || true
	fi
	if [[ -n $trace_pid ]] && ! wait_for_root_process_exit "$trace_pid"; then
		printf 'warning: bpftrace PID remains after SIGINT, sending SIGTERM: %s\n' \
			"$trace_pid" >&2
		sudo -n kill -TERM "$trace_pid" 2>/dev/null || true
		if ! wait_for_root_process_exit "$trace_pid"; then
			printf 'warning: bpftrace PID remains after SIGTERM, sending SIGKILL: %s\n' \
				"$trace_pid" >&2
			sudo -n kill -KILL "$trace_pid" 2>/dev/null || true
			wait_for_root_process_exit "$trace_pid" || true
		fi
	fi
	if [[ -n $trace_launcher_pid ]]; then
		wait "$trace_launcher_pid" 2>/dev/null || true
	fi
	if [[ -n $server_pid ]]; then
		sudo -n kill -TERM "$server_pid" 2>/dev/null || true
	elif [[ -n $server_launcher_pid ]]; then
		sudo -n kill -TERM "$server_launcher_pid" 2>/dev/null || true
	fi
	if [[ -n $server_pid ]] && ! wait_for_root_process_exit "$server_pid"; then
		printf 'warning: signal-server PID remains after SIGTERM, sending SIGKILL: %s\n' \
			"$server_pid" >&2
		sudo -n kill -KILL "$server_pid" 2>/dev/null || true
		wait_for_root_process_exit "$server_pid" || true
	fi
	if [[ -n $server_launcher_pid ]]; then
		wait "$server_launcher_pid" 2>/dev/null || true
	fi
}

[[ $# -ge 3 && $2 == -- ]] || {
	usage >&2
	exit 2
}
output_dir=$1
shift 2
command=("$@")

command -v "$BPFTRACE" >/dev/null 2>&1 || die "missing bpftrace: $BPFTRACE"
for required_command in awk curl rg sha256sum sudo; do
	command -v "$required_command" >/dev/null 2>&1 || \
		die "missing required command: $required_command"
done
[[ -r $TRACE_PROGRAM ]] || die "missing trace program: $TRACE_PROGRAM"
[[ -x $SIGNAL_SERVER ]] || die "missing signal server: $SIGNAL_SERVER"
[[ $TRACE_PORT =~ ^[0-9]+$ ]] || die "TRACE_PORT must be numeric"
sudo -n true 2>/dev/null || die "sudo credentials are not cached; run sudo -v"
[[ ! -e $output_dir ]] || die "refusing to reuse output directory: $output_dir"
mkdir -p "$output_dir"

for event in kvm/kvm_exit kvm/kvm_entry kvm/kvm_page_fault syscalls/sys_enter_write; do
	name=${event#*/}
	sudo -n test -r "$TRACE_ROOT/events/$event/format" || \
		die "missing tracepoint: ${event//\//:}"
	sudo -n cat "$TRACE_ROOT/events/$event/format" \
		>"$output_dir/$name.format"
done
sudo -n test -w "$TRACE_ROOT/trace_marker" || die "trace_marker is not writable"

printf '%q ' "${command[@]}" >"$output_dir/traced-command.txt"
printf '\n' >>"$output_dir/traced-command.txt"
token=$(< /proc/sys/kernel/random/uuid)
token=${token//-/}
trace_base_url="http://${CNI_GATEWAY}:${TRACE_PORT}/${token}"
{
	printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'kernel=%s\n' "$(uname -r)"
	printf 'bpftrace=%s\n' "$($BPFTRACE --version)"
	printf 'trace_program=%s\n' "$TRACE_PROGRAM"
	printf 'signal_server=%s\n' "$SIGNAL_SERVER"
	printf 'signal_port=%s\n' "$TRACE_PORT"
	printf 'trace_base_url=%s\n' "$trace_base_url"
	sha256sum "$TRACE_PROGRAM" "$SIGNAL_SERVER"
} >"$output_dir/trace-env.txt"

server_pidfile="$output_dir/signal-server.pid"
server_stdout="$output_dir/signal-server.stdout"
server_stderr="$output_dir/signal-server.stderr"
signal_log="$output_dir/signals.tsv"
trace_pidfile="$output_dir/bpftrace.pid"
trace_file="$output_dir/ept-events.tsv"
trace_stderr="$output_dir/bpftrace.stderr"
trap stop_processes EXIT INT TERM

sudo -n sh -c '
	printf "%s\n" "$$" >"$1"
	exec "$2" --bind 0.0.0.0 --port "$3" --token "$4" \
		--trace-marker "$5" --log "$6"
' sh "$server_pidfile" "$SIGNAL_SERVER" "$TRACE_PORT" "$token" \
	"$TRACE_ROOT/trace_marker" "$signal_log" \
	>"$server_stdout" 2>"$server_stderr" &
server_launcher_pid=$!

for _ in $(seq 1 100); do
	[[ ! -s $server_pidfile ]] || server_pid=$(<"$server_pidfile")
	if curl --connect-timeout 1 --max-time 1 -fsS \
		"http://127.0.0.1:${TRACE_PORT}/health" >/dev/null 2>&1; then
		break
	fi
	if [[ -n $server_pid ]] && ! root_process_alive "$server_pid"; then
		cat "$server_stderr" >&2 || true
		die "EPT signal server exited before becoming ready"
	elif [[ -z $server_pid ]] && ! root_process_alive "$server_launcher_pid"; then
		cat "$server_stderr" >&2 || true
		die "EPT signal-server launcher exited before publishing its PID"
	fi
	sleep 0.1
done
[[ -n $server_pid ]] || die "EPT signal server did not publish its PID"
curl --connect-timeout 1 --max-time 1 -fsS \
	"http://127.0.0.1:${TRACE_PORT}/health" >/dev/null || \
	die "EPT signal server did not become ready"

sudo -n sh -c '
	printf "%s\n" "$$" >"$1"
	export BPFTRACE_PERF_RB_PAGES=64
	exec "$2" -B line "$3" "$4"
' sh "$trace_pidfile" "$BPFTRACE" "$TRACE_PROGRAM" "$server_pid" \
	>"$trace_file" 2>"$trace_stderr" &
trace_launcher_pid=$!

for _ in $(seq 1 300); do
	[[ ! -s $trace_pidfile ]] || trace_pid=$(<"$trace_pidfile")
	if rg -q '^trace_status[[:space:]]+ready$' "$trace_file" 2>/dev/null; then
		break
	fi
	if [[ -n $trace_pid ]] && ! root_process_alive "$trace_pid"; then
		cat "$trace_stderr" >&2 || true
		die "bpftrace exited before becoming ready"
	elif [[ -z $trace_pid ]] && ! root_process_alive "$trace_launcher_pid"; then
		cat "$trace_stderr" >&2 || true
		die "bpftrace launcher exited before publishing its PID"
	fi
	sleep 0.1
done
[[ -n $trace_pid ]] || die "bpftrace did not publish its PID"
rg -q '^trace_status[[:space:]]+ready$' "$trace_file" || \
	die "bpftrace did not become ready within 30 seconds"

set +e
EPT_TRACE_BASE_URL="$trace_base_url" "${command[@]}"
command_rc=$?
set -e

stop_processes
trap - EXIT INT TERM
{
	printf 'finished=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'command_rc=%d\n' "$command_rc"
	printf 'trace_ready=%s\n' "$(count_matches '^trace_status[[:space:]]+ready$' "$trace_file")"
	printf 'trace_stopped=%s\n' "$(count_matches '^trace_status[[:space:]]+stopped$' "$trace_file")"
	printf 'ept_service_records=%s\n' "$(count_matches '^EPT_SERVICE[[:space:]]' "$trace_file")"
	printf 'vm_aggregate_records=%s\n' "$(count_matches '^@vm_' "$trace_file")"
	printf 'signal_begin_count=%s\n' "$(count_matches $'\tbegin$' "$signal_log")"
	printf 'signal_end_count=%s\n' "$(count_matches $'\tend$' "$signal_log")"
	printf 'loss_markers=%s\n' "$(count_matches_ci 'lost' "$trace_file" "$trace_stderr")"
} >"$output_dir/trace-result.txt"

printf 'trace_dir=%s\ncommand_rc=%d\n' "$output_dir" "$command_rc"
exit "$command_rc"
