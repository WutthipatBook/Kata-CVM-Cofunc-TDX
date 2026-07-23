import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class FaultSavingsHarnessTest(unittest.TestCase):
    def test_hugepage_probe_matches_workload_compaction_and_keeps_failure_state(self):
        probe = (ROOT / "scripts/run_oldabi_hugepage_only_probe.sh").read_text()
        self.assertIn('echo 1 >/proc/sys/vm/compact_memory', probe)
        self.assertIn('nr_hugepages-before-clean', probe)
        self.assertIn('meminfo-before-clean.txt', probe)
        self.assertIn('buddyinfo-before-clean.txt', probe)
        self.assertLess(
            probe.index('echo 1 >/proc/sys/vm/compact_memory'),
            probe.rindex('"$HUGEPAGE_SH"'),
        )

    def test_matrix_enables_network_free_image_derivation(self):
        harness = (ROOT / "scripts/run_cofunc_prefault_fault_savings.sh").read_text()
        self.assertIn("COFUNC_OLDABI_REUSE_LOCAL_FINAL_IMAGE=1", harness)
        self.assertIn("COFUNC_OLDABI_PREPARE_IMAGES_ONLY=1", harness)
        self.assertIn(
            "COFUNC_OLDABI_HUGEPAGE_PREFLIGHT_WORKLOAD=fn_py_dna_visualisation",
            harness,
        )
        prepare = harness.index("prepare_images\n")
        first_baseline = harness.index("capture_dmesg before")
        final_baseline = harness.rindex("capture_dmesg before")
        self.assertLess(first_baseline, prepare)
        self.assertLess(prepare, final_baseline)

    def test_local_derivation_replaces_only_instrumented_artifacts(self):
        wrapper = (
            ROOT / "scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh"
        ).read_text()
        start = wrapper.index("rebuild_workload_image_from_local_final()")
        end = wrapper.index("\nverify_workload_image()", start)
        function = wrapper[start:end]

        self.assertIn("FROM $source_image", function)
        self.assertIn("COPY tools/$template /func/$target", function)
        self.assertIn("chain_js_*)", function)
        self.assertIn("target=index.js", function)
        self.assertIn("target=main.js", function)
        self.assertIn(
            "COPY --from=builder /runtime/runtime /bin/sc-runtime", function
        )
        self.assertNotIn("RUN pip", function)
        self.assertNotIn("RUN apk", function)
        self.assertNotIn("docker pull", function)

    def test_preparation_only_stops_before_cvm_runner(self):
        wrapper = (
            ROOT / "scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh"
        ).read_text()
        prepare_gate = wrapper.index("if [[ $PREPARE_IMAGES_ONLY == 1 ]]")
        cvm_launch = wrapper.index('STOP_AFTER_SMOKE="$STOP_AFTER_SMOKE_VALUE"')
        self.assertLess(prepare_gate, cvm_launch)
        self.assertIn(
            "if [[ $PREPARE_IMAGES_ONLY == 0 ]]; then\n"
            "\t\t\t[[ -n ${COFUNC_EPT_TRACE_URL:-} ]]",
            wrapper,
        )

    def test_mode_hugepage_preflight_is_largest_and_precedes_cvm(self):
        wrapper = (
            ROOT / "scripts/run_oldabi_turbo_smp_bound_tdx_runtime_smoke.sh"
        ).read_text()
        self.assertIn('actual_pages == "$expected_pages"', wrapper)
        self.assertIn('after_pages == 0', wrapper)
        self.assertIn('"$HOST_SAFETY_GATE" "after-hugepage-preflight-', wrapper)
        self.assertLess(
            wrapper.index("run_hugepage_preflight\n"),
            wrapper.index('STOP_AFTER_SMOKE="$STOP_AFTER_SMOKE_VALUE"'),
        )

    def test_cvm_wrapper_reconfigures_and_proves_compiled_prefault_mode(self):
        wrapper = (
            ROOT / "scripts/run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh"
        ).read_text()
        configure = wrapper.index(
            'configure_kernel_prefault "$desired_prefault"'
        )
        clean = wrapper.index(
            'cmake --build "$KERNEL_BUILD" --target clean', configure
        )
        build = wrapper.index(
            'cmake --build . --target chcore.iso', clean
        )
        proof = wrapper.index(
            'verify_compiled_prefault "$desired_prefault"', build
        )
        launch = wrapper.index(
            '"running old-ABI workload set with diagnostic ISO', proof
        )
        self.assertLess(configure, clean)
        self.assertLess(clean, build)
        self.assertLess(build, proof)
        self.assertLess(proof, launch)
        self.assertIn(
            '-DCHCORE_SPLIT_CONTAINER_PREFAULT:BOOL="$value"', wrapper
        )
        self.assertIn(
            'grep -aFq "CoFunc private pre-fault:" "$image"', wrapper
        )

    def test_cvm_wrapper_restores_generated_cmake_state(self):
        wrapper = (
            ROOT / "scripts/run_oldabi_turbo_msr_skip_cpu_bound_smoke.sh"
        ).read_text()
        self.assertIn('"$BACKUP_DIR/configure-restore.rc"', wrapper)
        self.assertIn(
            'cp -a "$BACKUP_DIR/CMakeCache.txt.before" "$CMAKE_CACHE"',
            wrapper,
        )
        self.assertIn(
            'cp -a "$BACKUP_DIR/kernel-flags.make.before" "$KERNEL_FLAGS"',
            wrapper,
        )
        self.assertIn('"$CMAKE_CACHE" "$KERNEL_FLAGS"', wrapper)

    def test_matrix_can_reuse_only_validated_prefault_evidence(self):
        harness = (
            ROOT / "scripts/run_cofunc_prefault_fault_savings.sh"
        ).read_text()
        self.assertIn("COFUNC_REUSE_PREFAULT_MODE_ROOT", harness)
        reuse = harness[
            harness.index("reuse_prefault_mode()") :
            harness.index("\nprepare_images()", harness.index("reuse_prefault_mode()"))
        ]
        self.assertIn("source-state-before.sha256", reuse)
        self.assertIn("source-state-after.sha256", reuse)
        self.assertIn("prohibited-kernel-markers.txt", reuse)
        self.assertIn("postflight_gate_rc", reuse)
        self.assertIn("evidence_rc", reuse)
        self.assertIn("ON_DEMAND_CVM_PATCH", reuse)
        self.assertIn("CHCORE_SPLIT_CONTAINER_PREFAULT:BOOL=ON", reuse)
        self.assertIn("kernel.img.diagnostic", reuse)
        self.assertIn("chcore.iso.diagnostic", reuse)
        self.assertIn("experiment-inputs.sha256", reuse)
        self.assertIn("TRACE_WRAPPER", reuse)
        self.assertIn("TRACE_PROGRAM", reuse)
        self.assertIn("TRACE_PATCH", reuse)
        self.assertIn("verify_mode prefault", reuse)
        self.assertIn("reused-prefault-mode.sha256", reuse)
        self.assertIn("reused-prefault-output.sha256", reuse)
        self.assertIn("verify_reused_prefault_unchanged()", harness)
        self.assertIn(
            'sha256sum -c "$RUN_ROOT/reused-prefault-mode.sha256"', harness
        )
        self.assertIn(
            'sha256sum -c "$RUN_ROOT/reused-prefault-output.sha256"', harness
        )
        reuse_call = harness.rindex("reuse_prefault_mode\n")
        on_demand_call = harness.rindex(
            'run_mode on-demand "$ON_DEMAND_CVM_PATCH"'
        )
        self.assertLess(reuse_call, on_demand_call)

    def test_mode_paths_do_not_use_unbound_dependent_locals(self):
        harness = (
            ROOT / "scripts/run_cofunc_prefault_fault_savings.sh"
        ).read_text()
        self.assertNotIn("local mode=$1 mode_root=", harness)
        self.assertIn("mode=$1\n\tmode_root=$RUN_ROOT/$mode", harness)
        self.assertIn(
            "mode_root=$RUN_ROOT/$mode\n\tout=$mode_root/cofunc-out",
            harness,
        )


if __name__ == "__main__":
    unittest.main()
