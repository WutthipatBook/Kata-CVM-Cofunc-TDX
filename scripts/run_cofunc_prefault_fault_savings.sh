#!/usr/bin/env bash
# Count handler-window EPT faults once per Fig. 11 function in paired modes.
set -Eeuo pipefail

BUNDLE=${BUNDLE:-/home/booklyn/cofunc-tdx}
ROOT=${ROOT:-/mnt/new_disk/cofunc_tdx_artifact}
ARTIFACT=$ROOT/cofunc-artifact-oldabi
TRACE_WRAPPER=$BUNDLE/scripts/run_ept_trace_around.sh
TRACE_WRAPPER_PRE_LAUNCHER_FIX_SHA256=7949bd4d8ebceccfc233b91dfa3662995127e7632cafb44c6016268a09bcda69
TRACE_WRAPPER_LAUNCHER_FIX_SHA256=302a48f64ec22540079a0645c488ab542d91b9f738e145ee7bb905bf7df7af1a
TRACE_PROGRAM=$BUNDLE/scripts/cofunc_ept_fault_count.bt
BPFTRACE=${BPFTRACE:-/usr/local/bin/bpftrace}
ANALYZER=$BUNDLE/scripts/analyze_cofunc_prefault_fault_savings.py
TRACE_MERGER=$BUNDLE/scripts/merge_cofunc_ept_trace_segments.py
RUNNER=$BUNDLE/scripts/run_oldabi_turbo_smp_bound_tdx_runtime_instrumented.sh
GATE=$BUNDLE/scripts/kata_tdx_host_safety_gate.sh
OLD_PREFLIGHT=$BUNDLE/scripts/oldabi_tdx_host_preflight.sh
TRACE_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0017-Signal-CoFunc-handler-EPT-matrix-windows.patch
PREFAULT_CVM_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0006-Diagnostic-expose-guest-accept-pgfault-stats.patch
ON_DEMAND_CVM_PATCH=$BUNDLE/patches/cofunc-artifact-oldabi/0018-Diagnostic-disable-prefault-and-expose-stats.patch
STAMP=$(date -u +%Y%m%d_%H%M%S)
RUN_ROOT=${RUN_ROOT:-/home/booklyn/BookArchive/StageBreakdownRuns/cofunc_prefault_fault_savings_$STAMP}
REUSE_PREFAULT_MODE_ROOT=${COFUNC_REUSE_PREFAULT_MODE_ROOT:-}
REUSE_ON_DEMAND_PARTIAL_ROOT=${COFUNC_REUSE_ON_DEMAND_PARTIAL_ROOT:-}
REUSE_ON_DEMAND_THUMBNAIL_ROOT=${COFUNC_REUSE_ON_DEMAND_THUMBNAIL_ROOT:-}

CONFIG=$ARTIFACT/cvm_os/.config
SPLIT_C=$ARTIFACT/cvm_os/kernel/split-container/split_container.c
IRQ_C=$ARTIFACT/cvm_os/kernel/arch/x86_64/irq/irq_entry.c
CAP_GROUP_H=$ARTIFACT/cvm_os/kernel/include/object/cap_group.h
SNAPSHOT_C=$ARTIFACT/cvm_os/kernel/split-container/snapshot.c
ISO=$ARTIFACT/cvm_os/build/chcore.iso
KERNEL_ISO=$ARTIFACT/cvm_os/build/kernel/arch/x86_64/boot/intel_tdx/chcore.iso

WORKLOADS=(
	fn_py_compression
	fn_py_face_detection
	fn_py_image_processing
	fn_py_sentiment
	fn_py_video_processing
	fn_py_dna_visualisation
	fn_js_thumbnailer
	fn_js_uploader
	chain_js_alexa/fn_js_alexa_frontend
	chain_js_alexa/fn_js_alexa_interact
	chain_js_alexa/fn_js_alexa_smarthome
	chain_js_alexa/fn_js_alexa_tv
)
PARTIAL_WORKLOADS=("${WORKLOADS[@]:0:6}")
RESUME_WORKLOADS=("${WORKLOADS[@]:7}")

stop_re='BUG: Bad page state|TDH_MEM_RANGE_UNBLOCK.*failed|TDH_PHYMEM_PAGE_RECLAIM.*failed|TDX_TD_ASSOCIATED_PAGES_EXIST|TDX_PAGE_METADATA_INCORRECT|TDX_EPT_WALK_FAILED|tdx_sept_zap_private_spte|tdx_reclaim_page|WARNING:.*\[kvm(_intel)?\]'
log_loss_re='/dev/kmsg buffer overrun, some messages lost|Missed [0-9]+ kernel messages|[Ll]ost [0-9]+ kernel messages|messages dropped'
level2_re='CoFunc old-ABI TDX SEPT change:.*level=[2-9]|changed-live-split.*level=[2-9]|CoFunc TDX SEPT private lifecycle:.*level=[2-9]|CoFunc (old-ABI )?private TDP.*(level|iter_level|goal|req)=2|CoFunc TDX private TDP.*(level|iter_level)=2'
promotion_re='CoFunc old-ABI private 2M promotion|CoFunc.*private.*2M.*promot|CoFunc.*2M.*promot.*private'

run_rc=125
postflight_gate_rc=125
evidence_rc=0
active_phase=initializing
finished=0
completed_modes=()

fail() {
	run_rc=1
	printf 'error: %s\n' "$*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"
}

capture_dmesg() {
	local label=$1
	sudo -n dmesg --time-format iso >"$RUN_ROOT/dmesg-$label.log"
}

hash_source_state() {
	sha256sum "$CONFIG" "$SPLIT_C" "$IRQ_C" "$CAP_GROUP_H" \
		"$SNAPSHOT_C" "$ISO" "$KERNEL_ISO"
}

check_restoration_root() {
	local mode_root=$1
	local label=$2
	cmp -s "$mode_root/runtime-backup/sha256.before" \
		"$mode_root/runtime-backup/sha256.restored" \
		|| fail "$label runtime source restoration mismatch"
	cmp -s "$mode_root/cvm-backup/sha256.before" \
		"$mode_root/cvm-backup/sha256.restored" \
		|| fail "$label CVM source or boot restoration mismatch"
	[[ $(< "$mode_root/cvm-backup/build-clean.rc") == 0 ]] \
		|| fail "$label CVM build cleanup failed"
	if [[ -f $mode_root/cvm-backup/configure-restore.rc ]]; then
		[[ $(< "$mode_root/cvm-backup/configure-restore.rc") == 0 ]] \
			|| fail "$label CVM CMake restoration failed"
	fi
}

check_mode_restoration() {
	local mode=$1
	check_restoration_root "$RUN_ROOT/$mode" "$mode"
}

verify_mode() {
	local mode mode_root out
	local workload safe gate_count delta_count expected_prefault actual_prefault compiled_mode
	mode=$1
	mode_root=$RUN_ROOT/$mode
	out=$mode_root/cofunc-out
	[[ -L $out ]] || fail "missing $mode CoFunc output link"
	[[ $(awk -F= '$1 == "command_rc" { print $2 }' "$mode_root/ept-trace/trace-result.txt") == 0 ]] \
		|| fail "$mode traced command failed"
	[[ $(awk -F= '$1 == "signal_begin_count" { print $2 }' "$mode_root/ept-trace/trace-result.txt") == 12 ]] \
		|| fail "$mode trace does not contain 12 begin signals"
	[[ $(awk -F= '$1 == "signal_end_count" { print $2 }' "$mode_root/ept-trace/trace-result.txt") == 12 ]] \
		|| fail "$mode trace does not contain 12 end signals"
	[[ $(awk -F= '$1 == "loss_markers" { print $2 }' "$mode_root/ept-trace/trace-result.txt") == 0 ]] \
		|| fail "$mode trace reported loss"

	for workload in "${WORKLOADS[@]}"; do
		safe=${workload//\//_}
		[[ $(jq -s 'length' "$out/log/$workload/sc_fork.log") == 1 ]] \
			|| fail "$mode $workload does not have one analyzer row"
		jq -e -s 'length == 1 and (.[0].n_pgfault_exec | type == "number") and
			(.[0].t_pgfault_exec | type == "number") and
			(.[0].t_exec | type == "number")' \
			"$out/log/$workload/sc_fork.log" >/dev/null \
			|| fail "$mode $workload lacks fault telemetry"
		if [[ $mode == prefault ]]; then
			expected_prefault=1
		else
			expected_prefault=0
		fi
		actual_prefault=$(awk '/CoFunc private pre-fault:/{count++} END{print count+0}' \
			"$out/run-$safe-1.log")
		if [[ $expected_prefault == 1 && $actual_prefault -eq 0 ]]; then
			fail "$mode $workload lacks the pre-fault marker"
		fi
		if [[ $expected_prefault == 0 && $actual_prefault -ne 0 ]]; then
			fail "$mode $workload unexpectedly ran private pre-fault"
		fi
	done

	gate_count=$(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' \
		| awk 'END { print NR }')
	delta_count=$(find "$out/safety" -maxdepth 1 -type f -name 'dmesg-measured-*.delta' \
		| awk 'END { print NR }')
	[[ $gate_count == 24 ]] || fail "$mode expected 24 host gates, found $gate_count"
	[[ $delta_count == 12 ]] || fail "$mode expected 12 kernel deltas, found $delta_count"
	if [[ -n $(find "$out/safety" -maxdepth 1 -type f -name '*-prohibited.txt' \
		-size +0c -print -quit) ]]; then
		fail "$mode has prohibited per-workload kernel evidence"
	fi
	while IFS= read -r gate_log; do
		rg -q '^host_safety=ready$' "$gate_log" \
			|| fail "$mode host gate did not report ready: $gate_log"
	done < <(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' | sort)
	check_mode_restoration "$mode"
	[[ $(< "$mode_root/hugepage-preflight/nr_hugepages-after-alloc") == 512 ]] \
		|| fail "$mode HugeTLB preflight did not reserve 512 pages"
	[[ $(< "$mode_root/hugepage-preflight/nr_hugepages-after-clean") == 0 ]] \
		|| fail "$mode HugeTLB preflight did not restore the empty pool"
	rg -q '^host_safety=ready$' "$mode_root/hugepage-preflight/host-after.log" \
		|| fail "$mode post-HugeTLB host gate did not report ready"
	if [[ ! -L $mode_root ]]; then
		[[ -f $mode_root/cvm-backup/compiled-prefault-mode ]] \
			|| fail "$mode lacks compiled private pre-fault mode evidence"
		compiled_mode="$(< "$mode_root/cvm-backup/compiled-prefault-mode")"
		if [[ $mode == prefault ]]; then
			[[ $compiled_mode == ON ]] \
				|| fail "$mode compiled mode is $compiled_mode, expected ON"
		else
			[[ $compiled_mode == OFF ]] \
				|| fail "$mode compiled mode is $compiled_mode, expected OFF"
		fi
	fi
}

verify_on_demand_segment() {
	local mode sample_spec expected_count mode_root out
	local workload safe gate_count delta_count compiled_image
	mode=$1
	sample_spec=$2
	expected_count=$3
	shift 3
	local workloads=("$@")
	mode_root=$RUN_ROOT/$mode
	out=$mode_root/cofunc-out
	[[ -L $out ]] || fail "missing $mode CoFunc output link"
	"$TRACE_MERGER" validate \
		--root "$mode_root" \
		--samples "$sample_spec" \
		--command-rc 0 \
		--report "$mode_root/trace-validation.json" \
		>"$mode_root/trace-validation.stdout"

	[[ ${#workloads[@]} == "$expected_count" ]] \
		|| fail "$mode internal workload count mismatch"
	for workload in "${workloads[@]}"; do
		safe=${workload//\//_}
		[[ $(jq -s 'length' "$out/log/$workload/sc_fork.log") == 1 ]] \
			|| fail "$mode $workload does not have one analyzer row"
		jq -e -s 'length == 1 and (.[0].n_pgfault_exec | type == "number") and
			(.[0].t_pgfault_exec | type == "number") and
			(.[0].t_exec | type == "number")' \
			"$out/log/$workload/sc_fork.log" >/dev/null \
			|| fail "$mode $workload lacks fault telemetry"
		if rg -q 'CoFunc private pre-fault:' "$out/run-$safe-1.log"; then
			fail "$mode $workload unexpectedly ran private pre-fault"
		fi
	done

	gate_count=$(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' \
		| awk 'END { print NR }')
	delta_count=$(find "$out/safety" -maxdepth 1 -type f -name 'dmesg-measured-*.delta' \
		| awk 'END { print NR }')
	[[ $gate_count == $((expected_count * 2)) ]] \
		|| fail "$mode expected $((expected_count * 2)) host gates, found $gate_count"
	[[ $delta_count == "$expected_count" ]] \
		|| fail "$mode expected $expected_count kernel deltas, found $delta_count"
	if [[ -n $(find "$out/safety" -maxdepth 1 -type f -name '*-prohibited.txt' \
		-size +0c -print -quit) ]]; then
		fail "$mode has prohibited per-workload kernel evidence"
	fi
	while IFS= read -r gate_log; do
		rg -q '^host_safety=ready$' "$gate_log" \
			|| fail "$mode host gate did not report ready: $gate_log"
	done < <(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' | sort)

	check_restoration_root "$mode_root" "$mode"
	[[ $(< "$mode_root/hugepage-preflight/nr_hugepages-after-alloc") == 512 ]] \
		|| fail "$mode HugeTLB preflight did not reserve 512 pages"
	[[ $(< "$mode_root/hugepage-preflight/nr_hugepages-after-clean") == 0 ]] \
		|| fail "$mode HugeTLB preflight did not restore the empty pool"
	rg -q '^host_safety=ready$' "$mode_root/hugepage-preflight/host-after.log" \
		|| fail "$mode post-HugeTLB host gate did not report ready"
	[[ $(< "$mode_root/cvm-backup/compiled-prefault-mode") == OFF ]] \
		|| fail "$mode was not compiled in on-demand mode"
	for compiled_image in \
		"$mode_root/cvm-backup/kernel.img.diagnostic" \
		"$mode_root/cvm-backup/chcore.iso.diagnostic"; do
		[[ -f $compiled_image ]] \
			|| fail "$mode lacks compiled image: $compiled_image"
		if LC_ALL=C grep -aFq "CoFunc private pre-fault:" "$compiled_image"; then
			fail "$mode compiled image contains private pre-fault: $compiled_image"
		fi
	done
}

run_on_demand_resume() {
	local mode=on-demand-resume
	local mode_root=$RUN_ROOT/$mode
	local out=$ROOT/results/cofunc_on-demand_resume_fault_count_$STAMP
	local workload_list="${RESUME_WORKLOADS[*]}"
	local trace_rc
	[[ ! -e $mode_root ]] || fail "refusing to reuse mode root: $mode_root"
	[[ ! -e $out ]] || fail "refusing to reuse CoFunc output: $out"
	mkdir -p "$mode_root"
	printf '%s\n' "$out" >"$mode_root/cofunc-out.path"

	active_phase=$mode-trace
	set +e
	TRACE_PROGRAM="$TRACE_PROGRAM" CNI_GATEWAY=127.0.0.1 \
		"$TRACE_WRAPPER" "$mode_root/ept-trace" -- \
		bash -c '
			set -Eeuo pipefail
			: "${EPT_TRACE_BASE_URL:?missing EPT_TRACE_BASE_URL}"
			exec sudo -n env \
				ROOT="$1" BUNDLE="$2" OUT="$3" \
				COFUNC_OLDABI_RUNTIME_BACKUP_DIR="$4" \
				COFUNC_OLDABI_CVM_BACKUP_DIR="$5" \
				COFUNC_OLDABI_CVM_INSTRUMENTATION_PATCH="$6" \
				COFUNC_OLDABI_RUNTIME_TRACE_PATCH="$7" \
				COFUNC_OLDABI_RUNTIME_TRACE_MATRIX=1 \
				COFUNC_OLDABI_REUSE_LOCAL_FINAL_IMAGE=1 \
				COFUNC_OLDABI_HUGEPAGE_PREFLIGHT_WORKLOAD=fn_py_dna_visualisation \
				COFUNC_OLDABI_HUGEPAGE_PREFLIGHT_OUT="$(dirname "$4")/hugepage-preflight" \
				COFUNC_EPT_TRACE_URL="${EPT_TRACE_BASE_URL}" \
				STOP_AFTER_SMOKE=0 \
				COFUNC_OLDABI_SKIP_FACE_SMOKE=1 \
				COFUNC_OLDABI_RUNTIME_WORKLOADS="$8" \
				COFUNC_OLDABI_RUNTIME_REPETITIONS=1 \
				COFUNC_OLDABI_REGULAR_MEMFILE=0 \
				COFUNC_WORKLOAD_TIMEOUT_SEC=1200 \
				COFUNC_KVM_BUSY_RETRIES=1 \
				COFUNC_TDX_SMP=16 \
				COFUNC_HOST_SAFETY_GATE="$9" \
				COFUNC_KERNEL_GUARD=1 \
				"${10}"
		' bash "$ROOT" "$BUNDLE" "$out" \
			"$mode_root/runtime-backup" "$mode_root/cvm-backup" \
			"$ON_DEMAND_CVM_PATCH" "$TRACE_PATCH" "$workload_list" "$GATE" "$RUNNER" \
		2>&1 | tee "$mode_root/traced-runner.log"
	trace_rc=${PIPESTATUS[0]}
	set -e
	(( trace_rc == 0 )) || fail "$mode traced matrix failed: $trace_rc"
	ln -s "$out" "$mode_root/cofunc-out"
	verify_on_demand_segment "$mode" 8-12 5 "${RESUME_WORKLOADS[@]}"
	rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' "$CONFIG" \
		|| fail "$mode did not restore the pre-fault config"
}

run_mode() {
	local mode=$1 cvm_patch=$2
	local mode_root=$RUN_ROOT/$mode out=$ROOT/results/cofunc_${mode}_fault_count_$STAMP
	[[ ! -e $mode_root ]] || fail "refusing to reuse mode root: $mode_root"
	[[ ! -e $out ]] || fail "refusing to reuse CoFunc output: $out"
	mkdir -p "$mode_root"
	printf '%s\n' "$out" >"$mode_root/cofunc-out.path"

	active_phase=$mode-trace
	set +e
	TRACE_PROGRAM="$TRACE_PROGRAM" CNI_GATEWAY=127.0.0.1 \
		"$TRACE_WRAPPER" "$mode_root/ept-trace" -- \
		bash -c '
			set -Eeuo pipefail
			: "${EPT_TRACE_BASE_URL:?missing EPT_TRACE_BASE_URL}"
			exec sudo -n env \
				ROOT="$1" BUNDLE="$2" OUT="$3" \
				COFUNC_OLDABI_RUNTIME_BACKUP_DIR="$4" \
				COFUNC_OLDABI_CVM_BACKUP_DIR="$5" \
				COFUNC_OLDABI_CVM_INSTRUMENTATION_PATCH="$6" \
				COFUNC_OLDABI_RUNTIME_TRACE_PATCH="$7" \
				COFUNC_OLDABI_RUNTIME_TRACE_MATRIX=1 \
				COFUNC_OLDABI_REUSE_LOCAL_FINAL_IMAGE=1 \
				COFUNC_OLDABI_HUGEPAGE_PREFLIGHT_WORKLOAD=fn_py_dna_visualisation \
				COFUNC_OLDABI_HUGEPAGE_PREFLIGHT_OUT="$(dirname "$4")/hugepage-preflight" \
				COFUNC_EPT_TRACE_URL="${EPT_TRACE_BASE_URL}" \
				STOP_AFTER_SMOKE=0 \
				COFUNC_OLDABI_SKIP_FACE_SMOKE=1 \
				COFUNC_OLDABI_RUNTIME_WORKLOADS="$8" \
				COFUNC_OLDABI_RUNTIME_REPETITIONS=1 \
				COFUNC_OLDABI_REGULAR_MEMFILE=0 \
				COFUNC_WORKLOAD_TIMEOUT_SEC=1200 \
				COFUNC_KVM_BUSY_RETRIES=1 \
				COFUNC_TDX_SMP=16 \
				COFUNC_HOST_SAFETY_GATE="$9" \
				COFUNC_KERNEL_GUARD=1 \
				"${10}"
		' bash "$ROOT" "$BUNDLE" "$out" \
			"$mode_root/runtime-backup" "$mode_root/cvm-backup" \
			"$cvm_patch" "$TRACE_PATCH" "${WORKLOADS[*]}" "$GATE" "$RUNNER" \
		2>&1 | tee "$mode_root/traced-runner.log"
	trace_rc=${PIPESTATUS[0]}
	set -e
	(( trace_rc == 0 )) || fail "$mode traced matrix failed: $trace_rc"
	ln -s "$out" "$mode_root/cofunc-out"
	verify_mode "$mode"
	completed_modes+=("$mode")
	rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' "$CONFIG" \
		|| fail "$mode did not restore the pre-fault config"
}

reuse_prefault_mode() {
	local reuse_root prior_root prior_result out
	local compiled_image audited_input
	[[ $REUSE_PREFAULT_MODE_ROOT == /* ]] \
		|| fail "COFUNC_REUSE_PREFAULT_MODE_ROOT must be an absolute path"
	reuse_root="$(readlink -f -- "$REUSE_PREFAULT_MODE_ROOT")"
	[[ -d $reuse_root ]] || fail "missing reused pre-fault mode root: $reuse_root"
	[[ -L $reuse_root/cofunc-out ]] \
		|| fail "reused pre-fault mode lacks its CoFunc output link"
	out="$(readlink -f -- "$reuse_root/cofunc-out")"
	[[ -d $out ]] || fail "reused pre-fault CoFunc output is missing: $out"
	prior_root="$(dirname "$reuse_root")"
	[[ -f $prior_root/harness-result.txt ]] \
		|| fail "reused pre-fault parent lacks harness result"
	prior_result=$prior_root/harness-result.txt
	[[ $(awk -F= '$1 == "postflight_gate_rc" { print $2 }' "$prior_result") == 0 ]] \
		|| fail "reused pre-fault parent postflight failed"
	[[ $(awk -F= '$1 == "evidence_rc" { print $2 }' "$prior_result") == 0 ]] \
		|| fail "reused pre-fault parent evidence check failed"
	cmp -s "$prior_root/source-state-before.sha256" \
		"$prior_root/source-state-after.sha256" \
		|| fail "reused pre-fault parent did not restore source and boot state"
	[[ ! -s $prior_root/prohibited-kernel-markers.txt ]] \
		|| fail "reused pre-fault parent has prohibited kernel evidence"
	rg -q '^host_safety=ready$' "$prior_root/postflight.log" \
		|| fail "reused pre-fault parent postflight was not ready"
	rg -q "^cofunc_oldabi_cvm_extra_patch=.*/$(basename "$ON_DEMAND_CVM_PATCH")$" \
		"$reuse_root/cvm-backup/options" \
		|| fail "reused pre-fault mode does not use the audited instrumentation patch"
	rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' \
		"$reuse_root/cvm-backup/config.before" \
		|| fail "reused pre-fault mode did not start from the enabled baseline"
	for compiled_image in \
		"$reuse_root/cvm-backup/kernel.img.diagnostic" \
		"$reuse_root/cvm-backup/chcore.iso.diagnostic"; do
		[[ -f $compiled_image ]] \
			|| fail "reused pre-fault mode lacks compiled image: $compiled_image"
		LC_ALL=C grep -aFq "CoFunc private pre-fault:" "$compiled_image" \
			|| fail "reused compiled image lacks private pre-fault: $compiled_image"
	done
	for audited_input in "$TRACE_WRAPPER" "$TRACE_PROGRAM" "$ANALYZER" "$RUNNER" \
		"$TRACE_PATCH" "$ON_DEMAND_CVM_PATCH"; do
		verify_prior_input_hash "$prior_root/experiment-inputs.sha256" "$audited_input"
	done

	ln -s "$reuse_root" "$RUN_ROOT/prefault"
	verify_mode prefault
	{
		printf 'reused_mode_root=%s\n' "$reuse_root"
		printf 'reused_parent_root=%s\n' "$prior_root"
		printf 'reused_cofunc_out=%s\n' "$out"
		printf 'reused_parent_run_rc=%s\n' \
			"$(awk -F= '$1 == "run_rc" { print $2 }' "$prior_result")"
		printf 'validation=passed\n'
	} >"$RUN_ROOT/reused-prefault-provenance.txt"
	find "$reuse_root" -type f -print0 | sort -z | xargs -0 sha256sum \
		>"$RUN_ROOT/reused-prefault-mode.sha256"
	find "$out" -type f -print0 | sort -z | xargs -0 sha256sum \
		>"$RUN_ROOT/reused-prefault-output.sha256"
	completed_modes+=("prefault(reused)")
}

verify_reused_prefault_unchanged() {
	[[ -n $REUSE_PREFAULT_MODE_ROOT ]] || return
	sha256sum -c "$RUN_ROOT/reused-prefault-mode.sha256" \
		>"$RUN_ROOT/reused-prefault-mode.verify" 2>&1 \
		|| fail "reused pre-fault mode changed during on-demand collection"
	sha256sum -c "$RUN_ROOT/reused-prefault-output.sha256" \
		>"$RUN_ROOT/reused-prefault-output.verify" 2>&1 \
		|| fail "reused pre-fault output changed during on-demand collection"
}

verify_prior_input_hash() {
	local manifest=$1
	local input=$2
	local prior_hash current_hash
	prior_hash="$(awk -v path="$input" '$2 == path { print $1 }' "$manifest")"
	current_hash="$(sha256sum "$input" | awk '{ print $1 }')"
	[[ -n $prior_hash ]] \
		|| fail "reused mode lacks audited input hash: $input"
	if [[ $prior_hash == "$current_hash" ]]; then
		return
	fi
	if [[ $input == "$TRACE_WRAPPER" &&
		$prior_hash == "$TRACE_WRAPPER_PRE_LAUNCHER_FIX_SHA256" &&
		$current_hash == "$TRACE_WRAPPER_LAUNCHER_FIX_SHA256" ]]; then
		{
			printf 'manifest=%s\n' "$manifest"
			printf 'input=%s\n' "$input"
			printf 'prior_sha256=%s\n' "$prior_hash"
			printf 'current_sha256=%s\n' "$current_hash"
			printf 'compatibility=launcher-liveness-and-cleanup-only\n\n'
		} >>"$RUN_ROOT/trace-wrapper-compatibility.txt"
		return
	fi
	fail "reused mode input differs from current audited input: $input"
}

verify_external_on_demand_mode() {
	local mode_root=$1
	local label=$2
	local compiled_image
	check_restoration_root "$mode_root" "$label"
	[[ $(< "$mode_root/cvm-backup/compiled-prefault-mode") == OFF ]] \
		|| fail "$label was not compiled in true on-demand mode"
	rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' \
		"$mode_root/cvm-backup/config.before" \
		|| fail "$label did not start from the enabled baseline"
	rg -q "^cofunc_oldabi_cvm_extra_patch=.*/$(basename "$ON_DEMAND_CVM_PATCH")$" \
		"$mode_root/cvm-backup/options" \
		|| fail "$label did not use the on-demand CVM patch"
	for compiled_image in \
		"$mode_root/cvm-backup/kernel.img.diagnostic" \
		"$mode_root/cvm-backup/chcore.iso.diagnostic"; do
		[[ -f $compiled_image ]] || fail "$label lacks compiled image: $compiled_image"
		if LC_ALL=C grep -aFq "CoFunc private pre-fault:" "$compiled_image"; then
			fail "$label compiled image contains private pre-fault: $compiled_image"
		fi
	done
	[[ $(< "$mode_root/hugepage-preflight/nr_hugepages-after-alloc") == 512 ]] \
		|| fail "$label HugeTLB preflight did not reserve 512 pages"
	[[ $(< "$mode_root/hugepage-preflight/nr_hugepages-after-clean") == 0 ]] \
		|| fail "$label HugeTLB preflight did not restore the empty pool"
	rg -q '^host_safety=ready$' "$mode_root/hugepage-preflight/host-after.log" \
		|| fail "$label post-HugeTLB gate was not ready"
}

reuse_on_demand_partial() {
	local reuse_root prior_root prior_result out workload safe
	local gate_count delta_count audited_input
	[[ $REUSE_ON_DEMAND_PARTIAL_ROOT == /* ]] \
		|| fail "COFUNC_REUSE_ON_DEMAND_PARTIAL_ROOT must be an absolute path"
	reuse_root="$(readlink -f -- "$REUSE_ON_DEMAND_PARTIAL_ROOT")"
	[[ -d $reuse_root ]] || fail "missing reused on-demand partial root: $reuse_root"
	[[ -s $reuse_root/cofunc-out.path ]] \
		|| fail "reused on-demand partial lacks its output path"
	out="$(< "$reuse_root/cofunc-out.path")"
	[[ -d $out ]] || fail "reused on-demand partial output is missing: $out"
	prior_root="$(dirname "$reuse_root")"
	prior_result=$prior_root/harness-result.txt
	[[ -f $prior_result ]] || fail "reused on-demand partial lacks parent result"
	[[ $(awk -F= '$1 == "run_rc" { print $2 }' "$prior_result") == 1 ]] \
		|| fail "reused on-demand partial parent has unexpected run_rc"
	[[ $(awk -F= '$1 == "postflight_gate_rc" { print $2 }' "$prior_result") == 0 ]] \
		|| fail "reused on-demand partial parent postflight failed"
	[[ $(awk -F= '$1 == "evidence_rc" { print $2 }' "$prior_result") == 0 ]] \
		|| fail "reused on-demand partial parent evidence check failed"
	[[ $(awk -F= '$1 == "active_phase" { print $2 }' "$prior_result") == on-demand-trace ]] \
		|| fail "reused on-demand partial parent stopped in an unexpected phase"
	cmp -s "$prior_root/source-state-before.sha256" \
		"$prior_root/source-state-after.sha256" \
		|| fail "reused on-demand partial parent did not restore source and boot state"
	[[ ! -s $prior_root/prohibited-kernel-markers.txt ]] \
		|| fail "reused on-demand partial parent has prohibited kernel evidence"
	rg -q '^host_safety=ready$' "$prior_root/postflight.log" \
		|| fail "reused on-demand partial parent postflight was not ready"

	"$TRACE_MERGER" validate \
		--root "$reuse_root" \
		--samples 1-6 \
		--command-rc 124 \
		--report "$RUN_ROOT/reused-on-demand-partial-trace.json" \
		>"$RUN_ROOT/reused-on-demand-partial-trace.stdout"
	verify_external_on_demand_mode "$reuse_root" "reused on-demand partial"
	for workload in "${PARTIAL_WORKLOADS[@]}"; do
		safe=${workload//\//_}
		jq -e -s 'length == 1 and (.[0].n_pgfault_exec | type == "number") and
			(.[0].t_pgfault_exec | type == "number") and
			(.[0].t_exec | type == "number")' \
			"$out/log/$workload/sc_fork.log" >/dev/null \
			|| fail "reused partial $workload lacks one valid analyzer row"
		if rg -q 'CoFunc private pre-fault:' "$out/run-$safe-1.log"; then
			fail "reused partial $workload unexpectedly ran private pre-fault"
		fi
	done
	rg -q 'Environment::GetNow.*Assertion.*now.*timer_base' \
		"$out/run-fn_js_thumbnailer-1.log" \
		|| fail "reused partial lacks the classified pre-window Thumbnailer failure"
	[[ ! -s $out/log/fn_js_thumbnailer/sc_fork.log ]] \
		|| fail "reused partial failed Thumbnailer unexpectedly has analyzer data"
	gate_count=$(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' \
		| awk 'END { print NR }')
	delta_count=$(find "$out/safety" -maxdepth 1 -type f -name 'dmesg-measured-*.delta' \
		| awk 'END { print NR }')
	[[ $gate_count == 14 ]] \
		|| fail "reused partial expected 14 host gates, found $gate_count"
	[[ $delta_count == 7 ]] \
		|| fail "reused partial expected 7 kernel deltas, found $delta_count"
	if [[ -n $(find "$out/safety" -maxdepth 1 -type f -name '*-prohibited.txt' \
		-size +0c -print -quit) ]]; then
		fail "reused partial has prohibited per-workload kernel evidence"
	fi
	while IFS= read -r gate_log; do
		rg -q '^host_safety=ready$' "$gate_log" \
			|| fail "reused partial host gate did not report ready: $gate_log"
	done < <(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' | sort)
	for audited_input in "$TRACE_WRAPPER" "$TRACE_PROGRAM" "$ANALYZER" "$RUNNER" \
		"$TRACE_PATCH" "$ON_DEMAND_CVM_PATCH"; do
		verify_prior_input_hash "$prior_root/experiment-inputs.sha256" "$audited_input"
	done

	ln -s "$reuse_root" "$RUN_ROOT/on-demand-partial"
	{
		printf 'reused_mode_root=%s\n' "$reuse_root"
		printf 'reused_parent_root=%s\n' "$prior_root"
		printf 'reused_cofunc_out=%s\n' "$out"
		printf 'validated_samples=1-6\n'
		printf 'excluded_failure=fn_js_thumbnailer-pre-window\n'
		printf 'validation=passed\n'
	} >"$RUN_ROOT/reused-on-demand-partial-provenance.txt"
	find "$reuse_root" -type f -print0 | sort -z | xargs -0 sha256sum \
		>"$RUN_ROOT/reused-on-demand-partial-mode.sha256"
	find "$out" -type f -print0 | sort -z | xargs -0 sha256sum \
		>"$RUN_ROOT/reused-on-demand-partial-output.sha256"
}

reuse_on_demand_thumbnail() {
	local reuse_root prior_root prior_result out audited_input
	local gate_count delta_count result
	[[ $REUSE_ON_DEMAND_THUMBNAIL_ROOT == /* ]] \
		|| fail "COFUNC_REUSE_ON_DEMAND_THUMBNAIL_ROOT must be an absolute path"
	reuse_root="$(readlink -f -- "$REUSE_ON_DEMAND_THUMBNAIL_ROOT")"
	[[ -d $reuse_root ]] || fail "missing reused Thumbnailer mode root: $reuse_root"
	prior_root="$(dirname "$reuse_root")"
	prior_result=$prior_root/harness-result.txt
	[[ -f $prior_result ]] || fail "reused Thumbnailer probe lacks parent result"
	for result in run_rc workload_rc postflight_gate_rc evidence_rc; do
		[[ $(awk -F= -v key="$result" '$1 == key { print $2 }' "$prior_result") == 0 ]] \
			|| fail "reused Thumbnailer probe has nonzero $result"
	done
	[[ $(awk -F= '$1 == "probe_result" { print $2 }' "$prior_result") == workload-passed ]] \
		|| fail "reused Thumbnailer probe did not pass its workload"
	out="$(awk -F= '$1 == "cofunc_out" { print $2 }' "$prior_result")"
	[[ -d $out ]] || fail "reused Thumbnailer output is missing: $out"
	cmp -s "$prior_root/source-state-before.sha256" \
		"$prior_root/source-state-after.sha256" \
		|| fail "reused Thumbnailer probe did not restore source and boot state"
	[[ ! -s $prior_root/prohibited-kernel-markers.txt ]] \
		|| fail "reused Thumbnailer probe has prohibited kernel evidence"
	rg -q '^host_safety=ready$' "$prior_root/postflight.log" \
		|| fail "reused Thumbnailer probe postflight was not ready"

	"$TRACE_MERGER" validate \
		--root "$reuse_root" \
		--samples 7-7 \
		--command-rc 0 \
		--report "$RUN_ROOT/reused-on-demand-thumbnail-trace.json" \
		>"$RUN_ROOT/reused-on-demand-thumbnail-trace.stdout"
	verify_external_on_demand_mode "$reuse_root" "reused Thumbnailer probe"
	jq -e -s 'length == 1 and (.[0].n_pgfault_exec | type == "number") and
		(.[0].t_pgfault_exec | type == "number") and
		(.[0].t_exec | type == "number")' \
		"$out/log/fn_js_thumbnailer/sc_fork.log" >/dev/null \
		|| fail "reused Thumbnailer probe lacks one valid analyzer row"
	if rg -q 'CoFunc private pre-fault:' "$out/run-fn_js_thumbnailer-1.log"; then
		fail "reused Thumbnailer probe unexpectedly ran private pre-fault"
	fi
	gate_count=$(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' \
		| awk 'END { print NR }')
	delta_count=$(find "$out/safety" -maxdepth 1 -type f -name 'dmesg-measured-*.delta' \
		| awk 'END { print NR }')
	[[ $gate_count == 2 ]] \
		|| fail "reused Thumbnailer expected 2 host gates, found $gate_count"
	[[ $delta_count == 1 ]] \
		|| fail "reused Thumbnailer expected 1 kernel delta, found $delta_count"
	if [[ -n $(find "$out/safety" -maxdepth 1 -type f -name '*-prohibited.txt' \
		-size +0c -print -quit) ]]; then
		fail "reused Thumbnailer has prohibited per-workload kernel evidence"
	fi
	while IFS= read -r gate_log; do
		rg -q '^host_safety=ready$' "$gate_log" \
			|| fail "reused Thumbnailer host gate did not report ready: $gate_log"
	done < <(find "$out/safety" -maxdepth 1 -type f -name 'host-*.log' | sort)
	for audited_input in "$TRACE_WRAPPER" "$TRACE_PROGRAM" "$RUNNER" \
		"$TRACE_PATCH" "$ON_DEMAND_CVM_PATCH"; do
		verify_prior_input_hash "$prior_root/experiment-inputs.sha256" "$audited_input"
	done

	ln -s "$reuse_root" "$RUN_ROOT/on-demand-thumbnail"
	{
		printf 'reused_mode_root=%s\n' "$reuse_root"
		printf 'reused_parent_root=%s\n' "$prior_root"
		printf 'reused_cofunc_out=%s\n' "$out"
		printf 'validated_samples=7-7\n'
		printf 'validation=passed\n'
	} >"$RUN_ROOT/reused-on-demand-thumbnail-provenance.txt"
	find "$reuse_root" -type f -print0 | sort -z | xargs -0 sha256sum \
		>"$RUN_ROOT/reused-on-demand-thumbnail-mode.sha256"
	find "$out" -type f -print0 | sort -z | xargs -0 sha256sum \
		>"$RUN_ROOT/reused-on-demand-thumbnail-output.sha256"
}

verify_reused_on_demand_unchanged() {
	sha256sum -c "$RUN_ROOT/reused-on-demand-partial-mode.sha256" \
		>"$RUN_ROOT/reused-on-demand-partial-mode.verify" 2>&1 \
		|| fail "reused on-demand partial mode changed during resume"
	sha256sum -c "$RUN_ROOT/reused-on-demand-partial-output.sha256" \
		>"$RUN_ROOT/reused-on-demand-partial-output.verify" 2>&1 \
		|| fail "reused on-demand partial output changed during resume"
	sha256sum -c "$RUN_ROOT/reused-on-demand-thumbnail-mode.sha256" \
		>"$RUN_ROOT/reused-on-demand-thumbnail-mode.verify" 2>&1 \
		|| fail "reused Thumbnailer mode changed during resume"
	sha256sum -c "$RUN_ROOT/reused-on-demand-thumbnail-output.sha256" \
		>"$RUN_ROOT/reused-on-demand-thumbnail-output.verify" 2>&1 \
		|| fail "reused Thumbnailer output changed during resume"
}

copy_workload_evidence() {
	local source_out=$1
	local target_out=$2
	local workload=$3
	local safe=${workload//\//_}
	local source_file target_file
	mkdir -p "$target_out/log/$(dirname "$workload")" "$target_out/safety"
	[[ -d $source_out/log/$workload ]] \
		|| fail "missing source workload log directory: $source_out/log/$workload"
	cp -a "$source_out/log/$workload" "$target_out/log/$workload"
	for source_file in \
		"$source_out/run-$safe-1.log" \
		"$source_out/run-$safe-1-attempt-1.log"; do
		[[ -f $source_file ]] || fail "missing source run log: $source_file"
		cp -a "$source_file" "$target_out/"
	done
	for source_file in \
		"$source_out/safety/host-before-measured-$safe.log" \
		"$source_out/safety/host-after-measured-$safe.log" \
		"$source_out/safety/dmesg-measured-$safe-before.log" \
		"$source_out/safety/dmesg-measured-$safe-after.log" \
		"$source_out/safety/dmesg-measured-$safe.delta" \
		"$source_out/safety/measured-$safe-prohibited.txt"; do
		[[ -f $source_file ]] || fail "missing source safety evidence: $source_file"
		target_file=$target_out/safety/$(basename "$source_file")
		[[ ! -e $target_file ]] \
			|| fail "duplicate merged safety evidence: $target_file"
		cp -a "$source_file" "$target_file"
	done
}

merge_on_demand_segments() {
	local merged_root=$RUN_ROOT/on-demand
	local merged_out=$RUN_ROOT/on-demand-merged-output
	local partial_root partial_out thumbnail_root thumbnail_out resume_root resume_out
	local workload
	partial_root="$(readlink -f -- "$RUN_ROOT/on-demand-partial")"
	partial_out="$(< "$partial_root/cofunc-out.path")"
	thumbnail_root="$(readlink -f -- "$RUN_ROOT/on-demand-thumbnail")"
	thumbnail_out="$(awk -F= '$1 == "cofunc_out" { print $2 }' \
		"$(dirname "$thumbnail_root")/harness-result.txt")"
	resume_root=$RUN_ROOT/on-demand-resume
	resume_out="$(readlink -f -- "$resume_root/cofunc-out")"
	[[ ! -e $merged_root ]] || fail "refusing to reuse merged mode root: $merged_root"
	[[ ! -e $merged_out ]] || fail "refusing to reuse merged output: $merged_out"
	mkdir -p "$merged_root" "$merged_out/log" "$merged_out/safety"

	for workload in "${PARTIAL_WORKLOADS[@]}"; do
		copy_workload_evidence "$partial_out" "$merged_out" "$workload"
	done
	copy_workload_evidence "$thumbnail_out" "$merged_out" fn_js_thumbnailer
	for workload in "${RESUME_WORKLOADS[@]}"; do
		copy_workload_evidence "$resume_out" "$merged_out" "$workload"
	done

	"$TRACE_MERGER" merge \
		--segment "$partial_root" \
		--segment-samples 1-6 \
		--segment-command-rc 124 \
		--segment "$thumbnail_root" \
		--segment-samples 7-7 \
		--segment-command-rc 0 \
		--segment "$resume_root" \
		--segment-samples 8-12 \
		--segment-command-rc 0 \
		--output-dir "$merged_root/ept-trace" \
		>"$merged_root/trace-merge.stdout"
	ln -s "$merged_out" "$merged_root/cofunc-out"
	ln -s "$resume_root/runtime-backup" "$merged_root/runtime-backup"
	ln -s "$resume_root/cvm-backup" "$merged_root/cvm-backup"
	ln -s "$resume_root/hugepage-preflight" "$merged_root/hugepage-preflight"
	{
		printf 'format=cofunc-on-demand-merged-v1\n'
		printf 'samples_1_6_mode=%s\n' "$partial_root"
		printf 'sample_7_mode=%s\n' "$thumbnail_root"
		printf 'samples_8_12_mode=%s\n' "$resume_root"
		printf 'excluded_attempt=%s/run-fn_js_thumbnailer-1.log\n' "$partial_out"
		printf 'merged_output=%s\n' "$merged_out"
	} >"$merged_root/merge-provenance.txt"
	verify_mode on-demand
	find "$merged_out" -type f -print0 | sort -z | xargs -0 sha256sum \
		>"$merged_root/merged-output.sha256"
	completed_modes+=("on-demand(merged)")
}

prepare_images() {
	local prep_root=$RUN_ROOT/image-preflight
	local prep_rc
	mkdir -p "$prep_root"
	active_phase=image-preflight
	set +e
	sudo -n env \
		ROOT="$ROOT" BUNDLE="$BUNDLE" \
		OUT="$ROOT/results/cofunc_fault_savings_image_preflight_$STAMP" \
		COFUNC_OLDABI_RUNTIME_BACKUP_DIR="$prep_root/runtime-backup" \
		COFUNC_OLDABI_RUNTIME_TRACE_PATCH="$TRACE_PATCH" \
		COFUNC_OLDABI_RUNTIME_TRACE_MATRIX=1 \
		COFUNC_OLDABI_REUSE_LOCAL_FINAL_IMAGE=1 \
		COFUNC_OLDABI_PREPARE_IMAGES_ONLY=1 \
		STOP_AFTER_SMOKE=0 \
		COFUNC_OLDABI_SKIP_FACE_SMOKE=1 \
		COFUNC_OLDABI_RUNTIME_WORKLOADS="${WORKLOADS[*]}" \
		COFUNC_OLDABI_RUNTIME_REPETITIONS=1 \
		"$RUNNER" 2>&1 | tee "$prep_root/prepare.log"
	prep_rc=${PIPESTATUS[0]}
	set -e
	(( prep_rc == 0 )) || fail "network-free image preflight failed: $prep_rc"
	cmp -s "$prep_root/runtime-backup/sha256.before" \
		"$prep_root/runtime-backup/sha256.restored" \
		|| fail "image preflight did not restore runtime source"
	hash_source_state >"$prep_root/source-state-after.sha256"
	cmp -s "$RUN_ROOT/source-state-before.sha256" \
		"$prep_root/source-state-after.sha256" \
		|| fail "image preflight changed the source or boot baseline"
}

finish() {
	local entry_rc=$? final_rc match_re
	(( finished == 0 )) || return
	finished=1
	trap - EXIT
	set +e
	if [[ -r $RUN_ROOT/dmesg-before.log ]]; then
		capture_dmesg after
		{ diff -u "$RUN_ROOT/dmesg-before.log" "$RUN_ROOT/dmesg-after.log" 2>/dev/null || true; } \
			| sed -n '/^+[^+]/p' >"$RUN_ROOT/dmesg-after.delta"
		match_re="$stop_re|$log_loss_re|$level2_re|$promotion_re"
		if rg -n -i "$match_re" "$RUN_ROOT/dmesg-after.delta" \
			>"$RUN_ROOT/prohibited-kernel-markers.txt"; then
			evidence_rc=1
		else
			: >"$RUN_ROOT/prohibited-kernel-markers.txt"
		fi
	else
		evidence_rc=1
	fi
	sudo -n "$GATE" post-cofunc-prefault-fault-savings \
		>"$RUN_ROOT/postflight.log" 2>&1
	postflight_gate_rc=$?
	hash_source_state >"$RUN_ROOT/source-state-after.sha256" 2>/dev/null \
		|| evidence_rc=1
	if [[ -s $RUN_ROOT/source-state-before.sha256 && -s $RUN_ROOT/source-state-after.sha256 ]]; then
		cmp -s "$RUN_ROOT/source-state-before.sha256" "$RUN_ROOT/source-state-after.sha256" \
			|| evidence_rc=1
	else
		evidence_rc=1
	fi
	{
		printf 'run_rc=%d\n' "$run_rc"
		printf 'postflight_gate_rc=%d\n' "$postflight_gate_rc"
		printf 'evidence_rc=%d\n' "$evidence_rc"
		printf 'entry_rc=%d\n' "$entry_rc"
		printf 'active_phase=%s\n' "$active_phase"
		printf 'completed_modes=%s\n' "${completed_modes[*]}"
		printf 'run_root=%s\n' "$RUN_ROOT"
	} >"$RUN_ROOT/harness-result.txt"
	printf 'run_root=%s\n' "$RUN_ROOT"
	printf 'run_rc=%d postflight_gate_rc=%d evidence_rc=%d completed_modes=%s\n' \
		"$run_rc" "$postflight_gate_rc" "$evidence_rc" "${completed_modes[*]}"
	final_rc=$entry_rc
	(( run_rc == 0 )) || final_rc=$run_rc
	(( postflight_gate_rc == 0 )) || final_rc=$postflight_gate_rc
	(( evidence_rc == 0 )) || final_rc=$evidence_rc
	exit "$final_rc"
}

for command in awk bash basename cmp cp diff dirname dmesg docker find findmnt grep \
	jq patch ps python3 readlink rg sed sha256sum sort sudo tee xargs; do
	need "$command"
done
for executable in "$TRACE_WRAPPER" "$TRACE_MERGER" "$ANALYZER" "$RUNNER" \
	"$GATE" "$OLD_PREFLIGHT" "$BPFTRACE"; do
	[[ -x $executable ]] || fail "missing executable: $executable"
done
for input in "$TRACE_PROGRAM" "$TRACE_PATCH" "$PREFAULT_CVM_PATCH" "$ON_DEMAND_CVM_PATCH"; do
	[[ -r $input ]] || fail "missing input: $input"
done
sudo -n true 2>/dev/null || fail "sudo credentials are not cached; run sudo -v"
if [[ -n $REUSE_ON_DEMAND_PARTIAL_ROOT || -n $REUSE_ON_DEMAND_THUMBNAIL_ROOT ]]; then
	[[ -n $REUSE_ON_DEMAND_PARTIAL_ROOT && -n $REUSE_ON_DEMAND_THUMBNAIL_ROOT ]] \
		|| fail "both on-demand partial and Thumbnailer reuse roots are required"
	[[ -n $REUSE_PREFAULT_MODE_ROOT ]] \
		|| fail "on-demand resume also requires the validated pre-fault reuse root"
fi
[[ ! -e $RUN_ROOT ]] || fail "refusing to reuse run root: $RUN_ROOT"
mkdir -p "$RUN_ROOT"
trap finish EXIT

{
	printf 'run_started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'metric=handler-window host EPT page-fault tracepoint events\n'
	printf 'samples_per_function_per_mode=1\n'
	printf 'automatic_retries=0\n'
	printf 'workloads=%s\n' "${WORKLOADS[*]}"
	printf 'reuse_prefault_mode_root=%s\n' "$REUSE_PREFAULT_MODE_ROOT"
	printf 'reuse_on_demand_partial_root=%s\n' "$REUSE_ON_DEMAND_PARTIAL_ROOT"
	printf 'reuse_on_demand_thumbnail_root=%s\n' "$REUSE_ON_DEMAND_THUMBNAIL_ROOT"
} >"$RUN_ROOT/experiment-env.txt"
cp "$0" "$RUN_ROOT/harness.sh"
sha256sum "$0" "$TRACE_WRAPPER" "$TRACE_PROGRAM" "$TRACE_MERGER" "$ANALYZER" "$RUNNER" \
	"$TRACE_PATCH" "$PREFAULT_CVM_PATCH" "$ON_DEMAND_CVM_PATCH" \
	>"$RUN_ROOT/experiment-inputs.sha256"

active_phase=preflight
sudo -n "$GATE" pre-cofunc-prefault-fault-savings | tee "$RUN_ROOT/preflight.log"
sudo -n "$OLD_PREFLIGHT" | tee "$RUN_ROOT/oldabi-preflight.log"
rg -q '^CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON$' "$CONFIG" \
	|| fail "private pre-fault config is not enabled at baseline"
rg -q 'unsigned long sc_n_pgfault' "$CAP_GROUP_H" \
	|| fail "first-level page-fault counter source is missing"
patch --dry-run -d "$ARTIFACT" -p1 -i "$PREFAULT_CVM_PATCH" >/dev/null \
	|| fail "pre-fault CVM instrumentation patch does not apply"
patch --dry-run -d "$ARTIFACT" -p1 -i "$ON_DEMAND_CVM_PATCH" >/dev/null \
	|| fail "on-demand CVM instrumentation patch does not apply"
if ps -eo comm=,args= | awk '$1 == "bpftrace" { found=1 } END { exit !found }'; then
	fail "bpftrace is already active"
fi
sudo -n "$BPFTRACE" --dry-run "$TRACE_PROGRAM" 1 \
	>"$RUN_ROOT/bpftrace-dry-run.log" 2>&1 \
	|| fail "count-only EPT bpftrace program failed its dry-run"
hash_source_state >"$RUN_ROOT/source-state-before.sha256"
capture_dmesg before
prepare_images
capture_dmesg before

if [[ -n $REUSE_PREFAULT_MODE_ROOT ]]; then
	active_phase=prefault-reuse-validation
	reuse_prefault_mode
fi
if [[ -n $REUSE_ON_DEMAND_PARTIAL_ROOT ]]; then
	active_phase=on-demand-partial-reuse-validation
	reuse_on_demand_partial
	active_phase=on-demand-thumbnail-reuse-validation
	reuse_on_demand_thumbnail
	run_on_demand_resume
	active_phase=on-demand-merge
	merge_on_demand_segments
	verify_reused_on_demand_unchanged
else
	run_mode on-demand "$ON_DEMAND_CVM_PATCH"
fi
if [[ -z $REUSE_PREFAULT_MODE_ROOT ]]; then
	run_mode prefault "$PREFAULT_CVM_PATCH"
fi
verify_reused_prefault_unchanged

active_phase=analysis
"$ANALYZER" \
	--on-demand-root "$RUN_ROOT/on-demand" \
	--prefault-root "$RUN_ROOT/prefault" \
	--output-dir "$RUN_ROOT/analysis" | tee "$RUN_ROOT/analysis-result.txt"
find "$RUN_ROOT/analysis" -type f -print0 | sort -z | xargs -0 sha256sum \
	>"$RUN_ROOT/analysis.sha256"

active_phase=complete
run_rc=0
exit 0
