#!/usr/bin/env bash
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ARTIFACT_DIR=${ARTIFACT_DIR:-/mnt/new_disk/cofunc_tdx_artifact/cofunc-artifact}
PATCH_FILE=${PATCH_FILE:-$BUNDLE/patches/measurement/0001-Measure-exec-faults-cpu-and-network.patch}
BACKUP_ROOT=${BACKUP_ROOT:-/home/booklyn/BookArchive/KataTdxBackups}

usage() {
	cat <<'EOF'
Usage: manage_fault_instrumentation.sh apply|revert|status

Applies or removes the reversible process-fault instrumentation used by the
Native/Kata fault comparison. It does not build images or launch a VM.
EOF
}

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

state() {
	if patch -d "$ARTIFACT_DIR" -p1 --forward --dry-run <"$PATCH_FILE" >/dev/null 2>&1; then
		printf 'not-applied\n'
	elif patch -d "$ARTIFACT_DIR" -p1 --reverse --dry-run <"$PATCH_FILE" >/dev/null 2>&1; then
		printf 'applied\n'
	else
		printf 'diverged\n'
	fi
}

verify_instrumented() {
	rg -q '^print\(f"n_minflt_exec ' "$ARTIFACT_DIR/testcases/tools/template.py"
	rg -q '^print\(f"t_network ' "$ARTIFACT_DIR/testcases/tools/template.py"
	rg -q '^def fault_trace_signal\(phase\):' "$ARTIFACT_DIR/testcases/tools/template.py"
	rg -q '^def add_exec_resource_metrics\(\):' "$ARTIFACT_DIR/testcases/tools/analyze.py"
}

[[ $# == 1 ]] || {
	usage >&2
	exit 2
}
[[ -r $PATCH_FILE ]] || die "missing patch: $PATCH_FILE"
[[ -d $ARTIFACT_DIR/testcases/tools ]] || die "missing artifact tree: $ARTIFACT_DIR"

case "$1" in
status)
	printf 'instrumentation=%s\n' "$(state)"
	;;
apply)
	current=$(state)
	[[ $current == not-applied ]] || die "cannot apply from state: $current"
	stamp=$(date -u +%Y%m%d_%H%M%S)
	backup_dir="$BACKUP_ROOT/fault-instrumentation-pre-$stamp"
	mkdir -p "$backup_dir"
	cp -a "$ARTIFACT_DIR/testcases/tools/template.py" "$backup_dir/template.py"
	cp -a "$ARTIFACT_DIR/testcases/tools/analyze.py" "$backup_dir/analyze.py"
	sha256sum "$backup_dir/template.py" "$backup_dir/analyze.py" >"$backup_dir/SHA256SUMS"
	patch -d "$ARTIFACT_DIR" -p1 --forward <"$PATCH_FILE"
	verify_instrumented || die "post-apply verification failed"
	printf 'instrumentation=applied\nbackup_dir=%s\n' "$backup_dir"
	;;
revert)
	current=$(state)
	[[ $current == applied ]] || die "cannot revert from state: $current"
	patch -d "$ARTIFACT_DIR" -p1 --reverse <"$PATCH_FILE"
	[[ $(state) == not-applied ]] || die "post-revert verification failed"
	printf 'instrumentation=not-applied\n'
	;;
*)
	usage >&2
	exit 2
	;;
esac
