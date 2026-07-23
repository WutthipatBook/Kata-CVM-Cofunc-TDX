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


if __name__ == "__main__":
    unittest.main()
