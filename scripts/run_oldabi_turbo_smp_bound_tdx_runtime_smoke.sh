#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}"
BUNDLE="${BUNDLE:-/home/booklyn/cofunc-tdx}"
ARTIFACT="$ROOT/cofunc-artifact-oldabi"
SHADOW_DIR="$ARTIFACT/shadow_container"
RUNTIME_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0003-Use-TDX-shadow-runtime-config-diagnostic.patch"
HUGEPAGE_PATCH="$BUNDLE/patches/cofunc-artifact-oldabi/0004-Enable-hugepage-setup-for-old-ABI-run-sc-fork.patch"
RUNTIME_EXTRA_PATCH="${COFUNC_OLDABI_RUNTIME_EXTRA_PATCH:-}"
RUNTIME_FOLLOWUP_PATCH="${COFUNC_OLDABI_RUNTIME_FOLLOWUP_PATCH:-}"
RUNTIME_METRICS_PATCH="${COFUNC_OLDABI_RUNTIME_METRICS_PATCH:-}"
RUNTIME_TRACE_PATCH="${COFUNC_OLDABI_RUNTIME_TRACE_PATCH:-}"
CPU_SMOKE="$BUNDLE/scripts/run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh"
DEFAULT_WORKLOAD="fn_py_face_detection"
TOOLS="$ARTIFACT/testcases/tools"
CONFIG_H="$SHADOW_DIR/config.h"
SHADOW_MAIN_C="$SHADOW_DIR/main.c"
ACTION_SH="$ARTIFACT/testcases/tools/tasks/run_sc_fork/action.sh"
LEAN_START_SH="$ARTIFACT/testcases/tools/lean_container/start.sh"
TEMPLATE_PY="$TOOLS/template.py"
TEMPLATE_JS="$TOOLS/template.js"
ANALYZE_PY="$TOOLS/analyze.py"
STAMP="$(date -u +%Y%m%d_%H%M%S)"
BACKUP_DIR="${COFUNC_OLDABI_RUNTIME_BACKUP_DIR:-$BUNDLE/backups/oldabi-tdx-shadow-runtime-$STAMP}"
STOP_AFTER_SMOKE_VALUE="${STOP_AFTER_SMOKE:-1}"
SKIP_FACE_SMOKE_VALUE="${COFUNC_OLDABI_SKIP_FACE_SMOKE:-0}"
RUNTIME_REPETITIONS="${COFUNC_OLDABI_RUNTIME_REPETITIONS:-}"
OUT_KIND="smoke"
if [[ $STOP_AFTER_SMOKE_VALUE == 0 ]]; then
	OUT_KIND="fig11"
fi
OUT="${OUT:-$ROOT/results/oldabi_5_19_turbo_smp_bound_tdx_runtime_${OUT_KIND}_$STAMP}"
IMAGE_TAG_BACKUP="pre-oldabi-tdx-runtime-$STAMP"
RUNTIME_EXTRA_MARKERS='CoFunc grant/accept stat instrumentation|sc_host_grant_total_ns|STAT_N_ACCEPT|n_accept_exec|t_pgfault_exec|STAT_N_PGFAULT|n_pgfault_exec|sc_guest_tsc_hz|fault_trace_signal|COFUNC_EPT_TRACE_URL'
backup_done=0
SELECTED_WORKLOADS=()
DOCKER_BUILD_CACHE_ARGS=()
REBUILD_WORKLOAD_BASE_FOR_TEMPLATES=0

die() {
	echo "error: $*" >&2
	exit 1
}

log() {
	printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

ensure_rw() {
	findmnt /mnt/new_disk >/dev/null || die "/mnt/new_disk is not mounted"
	local opts
	opts="$(findmnt -no OPTIONS /mnt/new_disk)"
	if [[ ,$opts, == *,ro,* ]]; then
		log "remounting /mnt/new_disk read-write"
		mount -o remount,rw /mnt/new_disk
	fi
	opts="$(findmnt -no OPTIONS /mnt/new_disk)"
	[[ ,$opts, == *,rw,* ]] || die "/mnt/new_disk is not read-write: $opts"
}

backup_image() {
	local image=$1
	if docker image inspect "$image:latest" >/dev/null 2>&1; then
		docker tag "$image:latest" "$image:$IMAGE_TAG_BACKUP"
		printf '%s\n' "$image" >>"$BACKUP_DIR/docker-images.backed-up"
		docker image inspect "$image:latest" --format '{{.Id}} {{.Created}}' \
			>>"$BACKUP_DIR/docker-images.before"
	else
		printf '%s\n' "$image" >>"$BACKUP_DIR/docker-images.missing-before"
	fi
}

restore_images() {
	local image
	[[ -f "$BACKUP_DIR/docker-images.backed-up" ]] || return 0
	while read -r image; do
		[[ -n $image ]] || continue
		if docker image inspect "$image:$IMAGE_TAG_BACKUP" >/dev/null 2>&1; then
			docker tag "$image:$IMAGE_TAG_BACKUP" "$image:latest" >/dev/null
		fi
	done <"$BACKUP_DIR/docker-images.backed-up"
}

remove_copied_tools() {
	local dir=$1
	case "$dir" in
		"$ARTIFACT"/testcases/testcases/*) rm -rf "$dir/tools" ;;
	esac
}

workload_image() {
	basename "$1"
}

workload_dir() {
	printf '%s/testcases/testcases/%s\n' "$ARTIFACT" "$1"
}

selected_workload_contains() {
	local needle=$1 workload
	for workload in "${SELECTED_WORKLOADS[@]}"; do
		[[ $workload == "$needle" ]] && return 0
	done
	return 1
}

ensure_selected_workload() {
	local workload=$1
	if ! selected_workload_contains "$workload"; then
		SELECTED_WORKLOADS=("$workload" "${SELECTED_WORKLOADS[@]}")
	fi
}

rebuild_workload_image() {
	local dir=$1
	local image=$2
	local base_image="${image}_base"

	remove_copied_tools "$dir"
	if [[ -n $RUNTIME_EXTRA_PATCH ]]; then
		log "rebuilding $base_image:latest so workload template carries instrumentation"
		(
			cd "$dir"
			cp -r "$TOOLS" tools
			docker build -t "$base_image" .
			log "rebuilding final $image layer with diagnostic /bin/sc-runtime"
			docker build "${DOCKER_BUILD_CACHE_ARGS[@]}" -t "$image" -f tools/Dockerfile --build-arg BASE_NAME="$base_image" .
			"$TOOLS/lean_container/rootfs.sh" clean
			rm -rf tools
		)
	elif docker image inspect "$base_image:latest" >/dev/null 2>&1; then
		log "using existing $base_image:latest; rebuilding final $image layer only"
		(
			cd "$dir"
			cp -r "$TOOLS" tools
			docker build "${DOCKER_BUILD_CACHE_ARGS[@]}" -t "$image" -f tools/Dockerfile --build-arg BASE_NAME="$base_image" .
			"$TOOLS/lean_container/rootfs.sh" clean
			rm -rf tools
		)
	else
		log "missing $base_image:latest; falling back to full workload rebuild"
		(
			cd "$dir"
			"$TOOLS/build.sh"
			"$TOOLS/lean_container/rootfs.sh" clean
		)
	fi
}

verify_workload_image() {
	local workload=$1
	local image=$2
	local base_image="${image}_base"
	local interpreter check

	case "$workload" in
	fn_py_dna_visualisation)
		interpreter=/usr/local/bin/python
		check='import numpy; print("numpy=" + numpy.__version__); assert numpy.__version__ == "1.26.4"'
		;;
	fn_py_video_processing)
		interpreter=/usr/bin/python3
		check='import boto3, cv2; print("boto3=" + boto3.__version__); print("opencv=" + cv2.__version__)'
		;;
	*)
		return 0
		;;
	esac

	log "verifying $workload Python dependencies before any VM launch"
	docker image history --no-trunc "$base_image:latest" \
		>"$BACKUP_DIR/$image.base.history"
	if [[ $workload == "fn_py_dna_visualisation" ]]; then
		rg -Fq 'numpy==1.26.4' "$BACKUP_DIR/$image.base.history" \
			|| die "$base_image:latest history does not contain numpy==1.26.4"
	fi
	if ! docker run --rm --entrypoint "$interpreter" "$image:latest" -c "$check" \
		| tee "$BACKUP_DIR/$image.python-dependencies"; then
		die "$image:latest failed its pre-launch Python dependency check"
	fi
	if ! docker run --rm "$image:latest" sh -c \
		"grep -nF '_cofunc_syscall.restype = ctypes.c_long' /func/main.py && \
		 grep -nF 't_pgfault_after_exec = _cofunc_syscall(' /func/main.py && \
		 grep -nF 'n_pgfault_after_exec = _cofunc_syscall(' /func/main.py && \
		 grep -nF 'sc_guest_tsc_hz' /func/main.py" \
		| tee "$BACKUP_DIR/$image.syscall-restype"; then
		die "$image:latest does not contain the calibrated page-fault instrumentation"
	fi
	docker image inspect "$base_image:latest" "$image:latest" \
		>"$BACKUP_DIR/$image.verified-images.json"
}

cleanup() {
	local rc=$?
	local workload dir image
	set +e
	if ((backup_done)); then
		log "restoring old-ABI shadow runtime source and Docker image tags"
		cp -a "$BACKUP_DIR/config.h.before" "$CONFIG_H"
		cp -a "$BACKUP_DIR/shadow_main.c.before" "$SHADOW_MAIN_C"
		cp -a "$BACKUP_DIR/run_sc_fork_action.sh.before" "$ACTION_SH"
		cp -a "$BACKUP_DIR/lean_container_start.sh.before" "$LEAN_START_SH"
		cp -a "$BACKUP_DIR/template.py.before" "$TEMPLATE_PY"
		cp -a "$BACKUP_DIR/template.js.before" "$TEMPLATE_JS"
		cp -a "$BACKUP_DIR/analyze.py.before" "$ANALYZE_PY"
		restore_images
		for workload in "${SELECTED_WORKLOADS[@]}"; do
			dir="$(workload_dir "$workload")"
			(
				cd "$dir" || exit 0
				"$TOOLS/lean_container/rootfs.sh" clean >/dev/null 2>&1 || true
			)
			remove_copied_tools "$dir" || true
		done
		sha256sum "$CONFIG_H" "$SHADOW_MAIN_C" "$ACTION_SH" "$LEAN_START_SH" "$TEMPLATE_PY" "$TEMPLATE_JS" "$ANALYZE_PY" \
			>"$BACKUP_DIR/sha256.restored" 2>/dev/null || true
		if rg -q "$RUNTIME_EXTRA_MARKERS" "$SHADOW_MAIN_C" "$TEMPLATE_PY" "$TEMPLATE_JS" "$ANALYZE_PY"; then
			log "warning: runtime instrumentation marker still present after restore"
		fi
		docker image inspect split_container_builder:latest --format '{{.Id}} {{.Created}}' \
			>"$BACKUP_DIR/split_container_builder.restored" 2>/dev/null || true
		for workload in "${SELECTED_WORKLOADS[@]}"; do
			image="$(workload_image "$workload")"
			docker image inspect "$image:latest" --format '{{.Id}} {{.Created}}' \
				>"$BACKUP_DIR/$image.restored" 2>/dev/null || true
		done
		log "restore evidence: $BACKUP_DIR"
	fi
	exit "$rc"
}

main() {
	local workload dir image
	[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run with sudo: sudo $0"
	[[ -d "$SHADOW_DIR" ]] || die "missing shadow runtime dir: $SHADOW_DIR"
	[[ -f "$CONFIG_H" ]] || die "missing config: $CONFIG_H"
	[[ -f "$SHADOW_MAIN_C" ]] || die "missing shadow runtime main: $SHADOW_MAIN_C"
	[[ -f "$RUNTIME_PATCH" ]] || die "missing patch: $RUNTIME_PATCH"
	[[ -f "$HUGEPAGE_PATCH" ]] || die "missing patch: $HUGEPAGE_PATCH"
	if [[ -n $RUNTIME_EXTRA_PATCH ]]; then
		[[ -f "$RUNTIME_EXTRA_PATCH" ]] || die "missing extra runtime patch: $RUNTIME_EXTRA_PATCH"
	fi
	if [[ -n $RUNTIME_FOLLOWUP_PATCH ]]; then
		[[ -n $RUNTIME_EXTRA_PATCH ]] || die "runtime follow-up patch requires an extra runtime patch"
		[[ -f "$RUNTIME_FOLLOWUP_PATCH" ]] || die "missing runtime follow-up patch: $RUNTIME_FOLLOWUP_PATCH"
	fi
	if [[ -n $RUNTIME_METRICS_PATCH ]]; then
		[[ -n $RUNTIME_FOLLOWUP_PATCH ]] || die "runtime metrics patch requires the follow-up patch"
		[[ -f "$RUNTIME_METRICS_PATCH" ]] || die "missing runtime metrics patch: $RUNTIME_METRICS_PATCH"
	fi
	if [[ -n $RUNTIME_TRACE_PATCH ]]; then
		[[ -n $RUNTIME_METRICS_PATCH ]] || die "runtime trace patch requires the metrics patch"
		[[ -f "$RUNTIME_TRACE_PATCH" ]] || die "missing runtime trace patch: $RUNTIME_TRACE_PATCH"
		[[ -n ${COFUNC_EPT_TRACE_URL:-} ]] || die "runtime trace patch requires COFUNC_EPT_TRACE_URL"
	fi
	[[ -x "$CPU_SMOKE" ]] || die "missing smoke helper: $CPU_SMOKE"
	[[ -f "$ACTION_SH" ]] || die "missing run_sc_fork action: $ACTION_SH"
	[[ -f "$LEAN_START_SH" ]] || die "missing lean container start helper: $LEAN_START_SH"
	[[ -f "$TEMPLATE_PY" ]] || die "missing Python template: $TEMPLATE_PY"
	[[ -f "$TEMPLATE_JS" ]] || die "missing JS template: $TEMPLATE_JS"
	[[ -f "$ANALYZE_PY" ]] || die "missing analyzer: $ANALYZE_PY"
	[[ -x "$TOOLS/build.sh" ]] || die "missing testcase build helper: $TOOLS/build.sh"
	[[ -x "$TOOLS/lean_container/rootfs.sh" ]] || die "missing rootfs helper: $TOOLS/lean_container/rootfs.sh"
	[[ $STOP_AFTER_SMOKE_VALUE == 0 || $STOP_AFTER_SMOKE_VALUE == 1 ]] \
		|| die "STOP_AFTER_SMOKE must be 0 or 1, got $STOP_AFTER_SMOKE_VALUE"
	[[ $SKIP_FACE_SMOKE_VALUE == 0 || $SKIP_FACE_SMOKE_VALUE == 1 ]] \
		|| die "COFUNC_OLDABI_SKIP_FACE_SMOKE must be 0 or 1, got $SKIP_FACE_SMOKE_VALUE"

	if [[ $STOP_AFTER_SMOKE_VALUE == 1 ]]; then
		SELECTED_WORKLOADS=("${COFUNC_OLDABI_RUNTIME_WORKLOAD:-$DEFAULT_WORKLOAD}")
	elif [[ -n ${COFUNC_OLDABI_RUNTIME_WORKLOADS:-} ]]; then
		# shellcheck disable=SC2206
		SELECTED_WORKLOADS=(${COFUNC_OLDABI_RUNTIME_WORKLOADS})
	else
		SELECTED_WORKLOADS=(
			"fn_py_compression"
			"fn_py_face_detection"
			"fn_py_image_processing"
			"fn_py_sentiment"
			"fn_py_video_processing"
			"fn_py_dna_visualisation"
			"fn_js_thumbnailer"
			"fn_js_uploader"
			"chain_js_alexa/fn_js_alexa_frontend"
			"chain_js_alexa/fn_js_alexa_interact"
			"chain_js_alexa/fn_js_alexa_smarthome"
			"chain_js_alexa/fn_js_alexa_tv"
		)
	fi
	# The lower-level runner normally starts with this smoke action, so its image
	# must be rebuilt even when the main workload set is narrowed for diagnosis.
	if [[ $SKIP_FACE_SMOKE_VALUE == 0 ]]; then
		ensure_selected_workload "$DEFAULT_WORKLOAD"
	fi
	for workload in "${SELECTED_WORKLOADS[@]}"; do
		dir="$(workload_dir "$workload")"
		[[ -d "$dir" ]] || die "missing workload dir: $dir"
	done
	if [[ -n $RUNTIME_TRACE_PATCH ]]; then
		[[ ${#SELECTED_WORKLOADS[@]} -eq 1 ]] \
			|| die "runtime trace patch requires exactly one selected workload"
		[[ $SKIP_FACE_SMOKE_VALUE == 1 ]] \
			|| die "runtime trace patch requires COFUNC_OLDABI_SKIP_FACE_SMOKE=1"
		[[ $RUNTIME_REPETITIONS == 1 ]] \
			|| die "runtime trace patch requires COFUNC_OLDABI_RUNTIME_REPETITIONS=1"
	fi

	ensure_rw
	mkdir -p "$BACKUP_DIR"
	cp -a "$CONFIG_H" "$BACKUP_DIR/config.h.before"
	cp -a "$SHADOW_MAIN_C" "$BACKUP_DIR/shadow_main.c.before"
	cp -a "$ACTION_SH" "$BACKUP_DIR/run_sc_fork_action.sh.before"
	cp -a "$LEAN_START_SH" "$BACKUP_DIR/lean_container_start.sh.before"
	cp -a "$TEMPLATE_PY" "$BACKUP_DIR/template.py.before"
	cp -a "$TEMPLATE_JS" "$BACKUP_DIR/template.js.before"
	cp -a "$ANALYZE_PY" "$BACKUP_DIR/analyze.py.before"
	sha256sum "$CONFIG_H" "$SHADOW_MAIN_C" "$ACTION_SH" "$LEAN_START_SH" "$TEMPLATE_PY" "$TEMPLATE_JS" "$ANALYZE_PY" \
		>"$BACKUP_DIR/sha256.before"
	backup_image split_container_builder
	backup_done=1
	trap cleanup EXIT

		printf '%s\n' "${SELECTED_WORKLOADS[@]}" >"$BACKUP_DIR/workloads.selected"
	if [[ -n $RUNTIME_EXTRA_PATCH ]]; then
		DOCKER_BUILD_CACHE_ARGS=(--no-cache)
		REBUILD_WORKLOAD_BASE_FOR_TEMPLATES=1
	fi
	{
		printf 'cofunc_oldabi_runtime_extra_patch=%s\n' "$RUNTIME_EXTRA_PATCH"
		printf 'cofunc_oldabi_runtime_followup_patch=%s\n' "$RUNTIME_FOLLOWUP_PATCH"
		printf 'cofunc_oldabi_runtime_metrics_patch=%s\n' "$RUNTIME_METRICS_PATCH"
		printf 'cofunc_oldabi_runtime_trace_patch=%s\n' "$RUNTIME_TRACE_PATCH"
		printf 'cofunc_oldabi_skip_face_smoke=%s\n' "$SKIP_FACE_SMOKE_VALUE"
		printf 'cofunc_oldabi_regular_memfile=%s\n' "${COFUNC_OLDABI_REGULAR_MEMFILE:-0}"
		printf 'docker_build_cache_args=%s\n' "${DOCKER_BUILD_CACHE_ARGS[*]}"
		printf 'rebuild_workload_base_for_templates=%s\n' "$REBUILD_WORKLOAD_BASE_FOR_TEMPLATES"
	} >"$BACKUP_DIR/options"

	if rg -q 'CONFIG_PLAT_INTEL_TDX' "$CONFIG_H"; then
		die "old-ABI shadow runtime config already contains CONFIG_PLAT_INTEL_TDX; refusing to stack diagnostics"
	fi
	if [[ -n $RUNTIME_EXTRA_PATCH ]] && rg -q "$RUNTIME_EXTRA_MARKERS" "$SHADOW_MAIN_C" "$TEMPLATE_PY" "$TEMPLATE_JS" "$ANALYZE_PY"; then
		die "runtime instrumentation marker is already present; refusing to stack patches"
	fi

	log "applying old-ABI TDX shadow-runtime config patch"
	patch -d "$ARTIFACT" -p1 -i "$RUNTIME_PATCH"
	log "applying old-ABI run_sc_fork hugepage setup patch"
	patch -d "$ARTIFACT" -p1 -i "$HUGEPAGE_PATCH"
		if [[ -n $RUNTIME_EXTRA_PATCH ]]; then
			log "applying extra old-ABI runtime instrumentation patch: $RUNTIME_EXTRA_PATCH"
			patch -d "$ARTIFACT" -p1 -i "$RUNTIME_EXTRA_PATCH"
			rg -q 'sc_host_grant_total_ns' "$SHADOW_MAIN_C" \
				|| die "runtime extra patch did not add host grant metric marker"
			rg -q 'sc_guest_n_accept_before' "$TEMPLATE_PY" \
				|| die "runtime extra patch did not add Python raw guest stat markers"
			rg -q 'sc_guest_n_accept_before' "$TEMPLATE_JS" \
				|| die "runtime extra patch did not add JS raw guest stat markers"
			if [[ -n $RUNTIME_FOLLOWUP_PATCH ]]; then
				log "applying runtime instrumentation follow-up patch: $RUNTIME_FOLLOWUP_PATCH"
				patch -d "$ARTIFACT" -p1 -i "$RUNTIME_FOLLOWUP_PATCH"
				rg -q '_cofunc_syscall.restype = ctypes.c_long' "$TEMPLATE_PY" \
					|| die "runtime follow-up patch did not add the private 64-bit syscall binding"
				rg -q 't_pgfault_after_exec = _cofunc_syscall' "$TEMPLATE_PY" \
					|| die "runtime follow-up patch did not preserve the post-exec syscall binding"
			fi
			if [[ -n $RUNTIME_METRICS_PATCH ]]; then
				log "applying calibrated page-fault metrics patch: $RUNTIME_METRICS_PATCH"
				patch -d "$ARTIFACT" -p1 -i "$RUNTIME_METRICS_PATCH"
				rg -q 'n_pgfault_after_exec = _cofunc_syscall' "$TEMPLATE_PY" \
					|| die "runtime metrics patch did not add the Python fault count"
				rg -q 'sc_guest_tsc_hz' "$TEMPLATE_PY" "$TEMPLATE_JS" \
					|| die "runtime metrics patch did not add guest TSC telemetry"
				rg -q 'data\["sc_guest_tsc_hz"\]' "$ANALYZE_PY" \
					|| die "runtime metrics patch did not add calibrated analyzer conversion"
			fi
			if [[ -n $RUNTIME_TRACE_PATCH ]]; then
				log "applying handler EPT trace patch: $RUNTIME_TRACE_PATCH"
				patch -d "$ARTIFACT" -p1 -i "$RUNTIME_TRACE_PATCH"
				rg -q '^def fault_trace_signal\(phase\):$' "$TEMPLATE_PY" \
					|| die "runtime trace patch did not add Python trace signaling"
				rg -q 'EPT_TRACE_URL_PATH = "/func/\.cofunc-ept-trace-url"' "$TEMPLATE_PY" \
					|| die "runtime trace patch did not use the split-visible function path"
				rg -q 'trace_url_host="\.rootfs/\$name/func/\.cofunc-ept-trace-url"' "$LEAN_START_SH" \
					|| die "runtime trace patch did not populate the exported function rootfs"
				rg -q 'COFUNC_EPT_TRACE_URL' "$ACTION_SH" "$LEAN_START_SH" \
					|| die "runtime trace patch did not propagate the trace URL"
			fi
		fi
	sha256sum "$CONFIG_H" "$SHADOW_MAIN_C" "$ACTION_SH" "$LEAN_START_SH" "$TEMPLATE_PY" "$TEMPLATE_JS" "$ANALYZE_PY" \
		>"$BACKUP_DIR/sha256.diagnostic"
	rg -q '^[[:space:]]*\$tools/hugepage\.sh$' "$ACTION_SH" \
		|| die "run_sc_fork action does not call hugepage.sh after patch"
	rg -q 'COFUNC_OLDABI_REGULAR_MEMFILE' "$ACTION_SH" \
		|| die "run_sc_fork action does not preserve COFUNC_OLDABI_REGULAR_MEMFILE after patch"
	rg -q 'regular_memfile=.*COFUNC_OLDABI_REGULAR_MEMFILE' "$LEAN_START_SH" \
		|| die "lean container start helper does not honor COFUNC_OLDABI_REGULAR_MEMFILE after patch"

		log "building split_container_builder:latest from old-ABI TDX shadow runtime"
		(
			cd "$SHADOW_DIR"
			docker build "${DOCKER_BUILD_CACHE_ARGS[@]}" -t split_container_builder .
		) 2>&1 | tee "$BACKUP_DIR/split_container_builder.build.log"
		docker run --rm split_container_builder:latest sh -c \
			'grep -q "CONFIG_PLAT_INTEL_TDX" /runtime/config.h && grep -q "tdx.u.vmcall.subfunction" /runtime/main.c' \
			|| die "rebuilt builder image does not look like old-ABI TDX runtime source"
		if [[ -n $RUNTIME_EXTRA_PATCH ]]; then
			docker run --rm split_container_builder:latest grep -aFq "sc_host_grant_total_ns" /runtime/runtime \
				|| die "rebuilt builder image does not contain runtime instrumentation"
		fi
		docker image inspect split_container_builder:latest --format '{{.Id}} {{.Created}}' \
			>"$BACKUP_DIR/split_container_builder.diagnostic"

	for workload in "${SELECTED_WORKLOADS[@]}"; do
		dir="$(workload_dir "$workload")"
		image="$(workload_image "$workload")"
		backup_image "$image"
		backup_image "${image}_base"
		log "rebuilding $image image so /bin/sc-runtime comes from the old-ABI TDX builder"
		if [[ -d "$dir/tools" ]]; then
			log "removing leftover copied tools directory for $image"
			remove_copied_tools "$dir"
			fi
			rebuild_workload_image "$dir" "$image" 2>&1 | tee "$BACKUP_DIR/$image.build.log"
		if [[ -n $RUNTIME_EXTRA_PATCH ]]; then
			docker run --rm "$image:latest" grep -aFq "sc_host_grant_total_ns" /bin/sc-runtime \
				|| die "rebuilt $image image does not contain runtime instrumentation"
			docker run --rm "$image:latest" sh -c 'grep -R -q "sc_guest_n_accept_before" /func' \
				|| die "rebuilt $image image does not contain guest stat template instrumentation"
		fi
		if [[ -n $RUNTIME_TRACE_PATCH ]]; then
			docker run --rm "$image:latest" sh -c \
				'grep -Fq '\''fault_trace_signal("begin")'\'' /func/main.py && grep -Fq '\''EPT_TRACE_URL_PATH = "/func/.cofunc-ept-trace-url"'\'' /func/main.py' \
				|| die "rebuilt $image image does not contain handler trace signaling"
		fi
		verify_workload_image "$workload" "$image"
			docker image inspect "$image:latest" --format '{{.Id}} {{.Created}}' \
				>"$BACKUP_DIR/$image.diagnostic"
		done

	log "running Turbo-WRMSR-skip + SMP-bound workload set with old-ABI TDX shadow runtime: $OUT stop_after_smoke=$STOP_AFTER_SMOKE_VALUE"
	STOP_AFTER_SMOKE="$STOP_AFTER_SMOKE_VALUE" OUT="$OUT" "$CPU_SMOKE"
	log "diagnostic workload set completed: $OUT"
}

main "$@"
